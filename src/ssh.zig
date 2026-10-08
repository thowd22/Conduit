//! The SSH `ExecutionContext` (TASK-43, decision-8): every SSH workspace
//! process is a Local spawn of the system OpenSSH client riding one
//! ControlMaster connection per workspace.
//!
//! - **Master.** `connect` starts `ssh -M -N` in a PTY this context owns.
//!   OpenSSH's own host-key, passphrase, password and 2FA prompts appear in that
//!   terminal verbatim; the owner presents it through `masterTerminal` and the
//!   person answers by typing. Conduit never parses, stores or logs a prompt or
//!   an answer, never sets `StrictHostKeyChecking`, and never runs the master
//!   with `-v` (a verbose master logs every remote command).
//! - **Sessions.** `spawn` runs `ssh -tt -o ControlMaster=no` against the
//!   master. A client with no live master silently falls back to a direct
//!   connection, so a session is spawned only while the context is
//!   `connected`.
//! - **Exec channels.** `readFile`, `readFileAt`, `listDir`, `statPath`,
//!   `writeFile`, `makePrivateDir`, `stateDir`, `watch` and `run` run
//!   `ssh -T -o BatchMode=yes -o ControlMaster=no` over pipes, so they can
//!   never prompt where nobody can see it. A write's bytes travel on the
//!   channel's stdin in `write_chunk_bytes` pieces into a hidden temporary
//!   that the last piece renames into place; the only remote files Conduit
//!   writes this way are an agent's private sink (TASK-61).
//! - **State.** `disconnected` → `connecting` (master started) → `connected`
//!   (the master's control socket accepts connections, which OpenSSH binds only
//!   after authentication) → `lost` (the master exited, or a worker found it
//!   gone, without Conduit hanging it up) or `failed` (it exited before ever
//!   connecting); `disconnect` hangs up deliberately and lands on
//!   `disconnected`. Hang-up and loss both end the client with 255; the
//!   context tells them apart because it knows its own hang-ups.
//!
//! The user's `~/.ssh/config` is honoured because Conduit passes no `-F`
//! unless `Target.config_file` names one (tests do, since OpenSSH resolves
//! `~/.ssh` from the passwd database, not `$HOME`). Conduit's own control
//! options come first on every command line, and OpenSSH takes the first value
//! it sees, so neither the config nor `Target.options` can redirect the
//! master's socket.
//!
//! Remote commands are built by one quoting function and delivered in a form
//! no login shell can reinterpret (`remoteCommand`), so a cwd from OSC 7 or a
//! file reference (untrusted terminal data) is only ever a quoted argument.
//!
//! Threads: the owner thread (the one that owns the workspace) calls
//! `connect`, `poll`, `disconnect`, `reconnect`, `masterTerminal` and destroys
//! the context; the master PTY is touched only there. `spawn`, the file
//! capabilities and `run` may be called from any worker holding a `Ref`: they
//! read only immutable configuration and the atomically published state.
//! They block on a local `ssh` process, so the render thread must not call
//! them. A worker that finds the master gone reports it through an atomic
//! flag and the wake hook; the owner's next `poll` applies it. The context's
//! allocator must be thread-safe.
//!
//! Platforms: implemented and verified on Linux. macOS uses the same OpenSSH
//! design but its control-directory checks are not implemented here yet, and
//! Windows OpenSSH has no ControlMaster (decision-8); both report
//! `error.Unsupported` from `create`.

const std = @import("std");
const builtin = @import("builtin");
const pty = @import("pty");
const workspace = @import("workspace.zig");

const Allocator = std.mem.Allocator;
const ExecutionContext = workspace.ExecutionContext;
const log = std.log.scoped(.ssh);

/// Whether this build implements the SSH context.
pub const supported = builtin.os.tag == .linux;

/// Where the remote shell gets Conduit's shell integration from.
///
/// Only `off` is implemented: the remote shell starts without integration, so
/// SSH workspaces have no remote OSC 7 cwd or prompt marks yet. `auto` is the
/// hook for decision-8's content-addressed install
/// (`${XDG_CACHE_HOME:-$HOME/.cache}/conduit/shell-integration/<hash>/`) and
/// currently behaves as `off`.
pub const ShellIntegration = enum { off, auto };

/// What to connect to. Every slice is copied by `create`.
pub const Target = struct {
    /// A `~/.ssh/config` host alias or `[user@]host`. It must not begin with
    /// `-` or contain whitespace or control bytes.
    destination: []const u8,
    port: ?u16 = null,
    /// An explicit client configuration (`ssh -F`) instead of `~/.ssh/config`.
    /// Production leaves it null; tests isolate OpenSSH with it.
    config_file: ?[]const u8 = null,
    /// Extra `Key=Value` client options, each passed as `-o`. They come after
    /// Conduit's own control options, so they cannot override them.
    options: []const []const u8 = &.{},
    shell_integration: ShellIntegration = .off,
};

/// Called, from whichever thread noticed, when a worker finds the connection
/// gone, so an idle owner wakes and calls `poll`.
pub const Wake = struct {
    context: *anyopaque,
    wake_fn: *const fn (context: *anyopaque) void,
};

pub const Options = struct {
    target: Target,
    /// The local `ssh` client's whole environment for PTY spawns (master and
    /// sessions), copied. The client is a Local child and inherits Conduit's
    /// environment (TASK-73), so it sees `SSH_AUTH_SOCK`, `SSH_ASKPASS`,
    /// `DISPLAY` and `KRB5CCNAME`. Exec channels inherit the process
    /// environment directly.
    local_env: []const []const u8,
    /// `$XDG_RUNTIME_DIR`, when set. Control sockets live in
    /// `<runtime_dir>/conduit/ssh`, else `/tmp/conduit-<uid>/ssh`.
    runtime_dir: ?[]const u8 = null,
    /// The client program, found on `local_env`'s `PATH` when it has no `/`.
    ssh_program: []const u8 = "ssh",
    wake: ?Wake = null,
};

/// The connection's state, as the sidebar shows it.
pub const State = enum(u8) {
    disconnected,
    connecting,
    connected,
    lost,
    failed,
};

/// The pure connection state machine `SshContext` drives on its owner thread.
pub const Machine = struct {
    current: State = .disconnected,
    /// Whether Conduit itself hung the current master up.
    hung_up: bool = false,

    /// A new master process was started.
    pub fn started(self: *Machine) void {
        self.current = .connecting;
        self.hung_up = false;
    }

    /// The master's control socket answered.
    pub fn masterReady(self: *Machine) void {
        if (self.current == .connecting) self.current = .connected;
    }

    /// The master process ended. Its exit status (255 for both a hang-up and
    /// a dropped connection) cannot tell the two apart; `hung_up` can.
    pub fn masterExited(self: *Machine) void {
        if (self.hung_up) {
            self.current = .disconnected;
            return;
        }
        switch (self.current) {
            .connecting => self.current = .failed,
            .connected => self.current = .lost,
            .disconnected, .lost, .failed => {},
        }
    }

    /// Something found the master unreachable while it was thought connected.
    pub fn checkFailed(self: *Machine) void {
        if (!self.hung_up and self.current == .connected) self.current = .lost;
    }

    /// Conduit is hanging the master up on purpose.
    pub fn hangUp(self: *Machine) void {
        self.hung_up = true;
        self.current = .disconnected;
    }
};

/// How a session's `ssh` client ended, for the session's end banner.
pub const SessionEnd = enum {
    /// The remote program ended; its status is the session's.
    exited,
    /// The connection went away underneath it (`── connection lost ──`).
    disconnected,
};

/// Classify a session client's end (decision-8): exit 255 while the master is
/// gone and Conduit did not hang the session up is a lost connection;
/// anything else is the remote program's own end.
pub fn sessionEnd(status: pty.ExitStatus, hung_up_by_conduit: bool, master_alive: bool) SessionEnd {
    if (hung_up_by_conduit or master_alive) return .exited;
    return switch (status) {
        .code => |code| if (code == 255) .disconnected else .exited,
        .signal, .unknown => .exited,
    };
}

pub const QuoteError = Allocator.Error || error{EmbeddedNul};

/// Append `value` as one POSIX-shell single-quoted word: `'` becomes `'\''`
/// and nothing else is special. NUL cannot cross an argv and is refused.
pub fn appendQuoted(list: *std.ArrayList(u8), allocator: Allocator, value: []const u8) QuoteError!void {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
    try list.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try list.appendSlice(allocator, "'\\''");
        } else {
            try list.append(allocator, byte);
        }
    }
    try list.append(allocator, '\'');
}

/// Bytes `remoteCommand` passes through literally; every other byte is an
/// octal escape.
fn isLiteralByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        ' ', '_', '.', '/', ':', '=', ',', '+', '@', '-' => true,
        else => false,
    };
}

/// Wrap a POSIX `/bin/sh` script as the single remote command string `ssh`
/// sends, which the remote user's login shell parses first.
///
/// That login shell may be bash, zsh, fish or tcsh, which disagree about
/// quoting: fish treats `\\` and `\'` inside single quotes as escapes, and
/// csh-family shells cannot carry a newline inside quotes. The script is
/// therefore delivered as `exec /bin/sh -c 'eval "$(printf %b "…")"'`, where
/// `…` holds only letters, digits, a few punctuation marks and `\0ooo` octal
/// escapes: text every one of those shells passes through single quotes
/// unchanged, and that `/bin/sh` decodes back to the exact script. The caller
/// owns the result.
pub fn remoteCommand(allocator: Allocator, script: []const u8) QuoteError![]u8 {
    if (std.mem.indexOfScalar(u8, script, 0) != null) return error.EmbeddedNul;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "exec /bin/sh -c 'eval \"$(printf %b \"");
    for (script) |byte| {
        if (isLiteralByte(byte)) {
            try out.append(allocator, byte);
        } else {
            var escape: [5]u8 = undefined;
            _ = std.fmt.bufPrint(&escape, "\\0{o:0>3}", .{byte}) catch unreachable; // 5 bytes always fit "\0ooo".
            try out.appendSlice(allocator, &escape);
        }
    }
    try out.appendSlice(allocator, "\")\"'");
    return out.toOwnedSlice(allocator);
}

/// Whether `key` may name a remote environment variable.
fn validEnvKey(key: []const u8) bool {
    if (key.len == 0) return false;
    if (!(std.ascii.isAlphabetic(key[0]) or key[0] == '_')) return false;
    for (key[1..]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '_')) return false;
    }
    return true;
}

/// Variables the request's environment may carry that describe this machine
/// rather than the remote one. The remote host supplies its own `PATH`,
/// `HOME` and login identity; a local socket, display or temporary directory
/// means nothing there; and shell-integration handshake variables name local
/// files (remote integration is decision-8's content-addressed install, not
/// these).
const local_only_keys = [_][]const u8{
    "PATH",                          "HOME",                              "SHELL",               "USER",
    "LOGNAME",                       "PWD",                               "OLDPWD",              "TMPDIR",
    "MAIL",                          "DISPLAY",                           "WAYLAND_DISPLAY",     "DBUS_SESSION_BUS_ADDRESS",
    "ENV",                           "ZDOTDIR",                           "CONDUIT_BASH_INJECT", "CONDUIT_ZSH_ZDOTDIR",
    "CONDUIT_SHELL_INTEGRATION_DIR", "CONDUIT_SHELL_INTEGRATION_XDG_DIR",
};

/// Whether a request variable crosses to the remote side.
pub fn crossesToRemote(key: []const u8) bool {
    if (!validEnvKey(key)) return false;
    if (std.mem.startsWith(u8, key, "XDG_") or std.mem.startsWith(u8, key, "SSH_")) return false;
    for (local_only_keys) |local_key| {
        if (std.mem.eql(u8, key, local_key)) return false;
    }
    return true;
}

/// The marker an exec script prints when its working directory or program is
/// missing, so `run` can report `error.CommandNotFound` as Local does.
const not_found_marker = "conduit-ssh: not found";

/// Exit statuses the file helpers use for the errors `FsError` names. A
/// helper's own utilities never exit with these.
const helper_not_found = 64;
const helper_is_dir = 65;
const helper_access_denied = 66;
const helper_not_dir = 67;
const helper_failed = 68;

/// Append `cd -- '<cwd>'` and its failure branch.
fn appendCd(list: *std.ArrayList(u8), allocator: Allocator, cwd: []const u8, on_failure: []const u8) QuoteError!void {
    if (cwd.len == 0) return;
    try list.appendSlice(allocator, "cd -- ");
    try appendQuoted(list, allocator, cwd);
    try list.appendSlice(allocator, " 2>/dev/null || ");
    try list.appendSlice(allocator, on_failure);
    try list.appendSlice(allocator, "; ");
}

/// The `/bin/sh` script an interactive session runs: enter `cwd` (falling
/// back to the remote home), export each crossing `KEY=VALUE` of `env`, then
/// exec `argv`, or the remote login shell when `argv` is empty. Caller owns.
pub fn sessionScript(
    allocator: Allocator,
    cwd: []const u8,
    env: []const []const u8,
    argv: []const []const u8,
) QuoteError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendCd(&out, allocator, cwd, "cd");
    for (env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const key = entry[0..eq];
        if (!crossesToRemote(key)) continue;
        try out.appendSlice(allocator, "export ");
        try out.appendSlice(allocator, key);
        try out.append(allocator, '=');
        try appendQuoted(&out, allocator, entry[eq + 1 ..]);
        try out.appendSlice(allocator, "; ");
    }
    if (argv.len == 0) {
        try out.appendSlice(allocator, "exec \"${SHELL:-/bin/sh}\" -l");
    } else {
        try out.appendSlice(allocator, "exec");
        for (argv) |arg| {
            try out.append(allocator, ' ');
            try appendQuoted(&out, allocator, arg);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// The `/bin/sh` script `run` executes: `argv` in `cwd`, with a missing
/// directory or program reported by `not_found_marker`. Caller owns.
pub fn execScript(allocator: Allocator, cwd: []const u8, argv: []const []const u8) QuoteError![]u8 {
    std.debug.assert(argv.len > 0);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const missing = "{ printf '%s\\n' '" ++ not_found_marker ++ "' >&2; exit 127; }";
    try appendCd(&out, allocator, cwd, missing);
    try out.appendSlice(allocator, "command -v ");
    try appendQuoted(&out, allocator, argv[0]);
    try out.appendSlice(allocator, " >/dev/null 2>&1 || " ++ missing ++ "; exec");
    for (argv) |arg| {
        try out.append(allocator, ' ');
        try appendQuoted(&out, allocator, arg);
    }
    return out.toOwnedSlice(allocator);
}

fn pathScript(allocator: Allocator, path: []const u8, body: []const u8) QuoteError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "p=");
    try appendQuoted(&out, allocator, path);
    try out.appendSlice(allocator, "; ");
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

/// Read at most `limit` bytes of a file; a caller asks for one more than it
/// accepts to detect truncation.
pub fn readFileScript(allocator: Allocator, path: []const u8, limit: usize) QuoteError![]u8 {
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer,
        \\[ -d "$p" ] && exit {d}; [ -e "$p" ] || exit {d}; [ -r "$p" ] || exit {d}; exec head -c {d} -- "$p"
    , .{ helper_is_dir, helper_not_found, helper_access_denied, limit }) catch unreachable; // A fixed template and four integers fit 512 bytes.
    return pathScript(allocator, path, body);
}

/// List a directory as NUL-terminated records, each a kind byte (`f`, `d` or
/// `o`) followed by the name. Kinds follow symbolic links, as Local's do;
/// no GNU `find -printf`, so BSD and busybox remotes work.
pub fn listDirScript(allocator: Allocator, path: []const u8) QuoteError![]u8 {
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer,
        \\[ -e "$p" ] || exit {d}; [ -d "$p" ] || exit {d}; cd -- "$p" 2>/dev/null || exit {d}; for n in * .[!.]* ..?*; do if [ -d "$n" ]; then k=d; elif [ -f "$n" ]; then k=f; elif [ -e "$n" ] || [ -L "$n" ]; then k=o; else continue; fi; printf '%s%s\0' "$k" "$n"; done
    , .{ helper_not_found, helper_not_dir, helper_access_denied }) catch unreachable; // A fixed template and three integers fit 512 bytes.
    return pathScript(allocator, path, body);
}

/// Describe a path as one line `<kind> <size> <mtime seconds[.fraction]>`,
/// trying GNU `stat` with nanoseconds, then whole seconds, then BSD `stat`.
pub fn statScript(allocator: Allocator, path: []const u8) QuoteError![]u8 {
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer,
        \\[ -e "$p" ] || exit {d}; if [ -d "$p" ]; then k=d; elif [ -f "$p" ]; then k=f; else k=o; fi; m=$(stat -L -c '%s %.9Y' -- "$p" 2>/dev/null) || m=$(stat -L -c '%s %Y' -- "$p" 2>/dev/null) || m=$(stat -L -f '%z %m' -- "$p" 2>/dev/null) || exit {d}; printf '%s %s\n' "$k" "$m"
    , .{ helper_not_found, helper_failed }) catch unreachable; // A fixed template and two integers fit 512 bytes.
    return pathScript(allocator, path, body);
}

/// Read at most `limit` bytes of a file starting at byte `offset`
/// (`tail -c +N | head -c L`, both POSIX), so an append-only sink is followed
/// without rereading it.
pub fn readFileAtScript(allocator: Allocator, path: []const u8, offset: u64, limit: usize) QuoteError![]u8 {
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer,
        \\[ -d "$p" ] && exit {d}; [ -e "$p" ] || exit {d}; [ -r "$p" ] || exit {d}; tail -c +{d} -- "$p" | head -c {d}
    , .{ helper_is_dir, helper_not_found, helper_access_denied, offset + 1, limit }) catch unreachable; // A fixed template and five integers fit 512 bytes.
    return pathScript(allocator, path, body);
}

/// The bytes one write exec channel carries on its stdin, so a remote write
/// of up to `workspace.max_write_bytes` is at most 64 channels and stdin is
/// always within what `runLocalProcess` writes up front.
pub const write_chunk_bytes = workspace.RunRequest.max_stdin;

/// One step of an atomic remote write (`writeFileScript`).
pub const WriteStep = struct {
    /// Truncate the temporary file before appending this chunk; otherwise
    /// it must already exist from the previous step.
    first: bool,
    /// After this chunk, set `mode` on the temporary file and rename it over
    /// the destination.
    last: bool,
    mode: u32,
};

/// The shell fragment every failed write step ends with.
const write_failed = "{ rm -f -- \"$t\"; exit " ++ std.fmt.comptimePrint("{d}", .{helper_failed}) ++ "; }";

/// One exec channel of a remote write: create the destination's missing
/// parents private (under `umask 077`), append stdin to the hidden temporary
/// file `tmp` beside it, and on the last step `chmod` and `mv` it into place,
/// which is atomic within the directory. A failure removes the temporary.
/// A destination that is a directory is refused rather than moved into.
/// Caller owns.
pub fn writeFileScript(allocator: Allocator, path: []const u8, tmp: []const u8, step: WriteStep) QuoteError![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "p=");
    try appendQuoted(&out, allocator, path);
    try out.appendSlice(allocator, "; t=");
    try appendQuoted(&out, allocator, tmp);
    var buffer: [256]u8 = undefined;
    try out.appendSlice(allocator, std.fmt.bufPrint(&buffer,
        \\; umask 077; [ -d "$p" ] && exit {d}; d=${{p%/*}}; [ -n "$d" ] || d=/; mkdir -p -- "$d" 2>/dev/null; [ -d "$d" ] || {{ [ -e "$d" ] && exit {d}; exit {d}; }};
    , .{ helper_is_dir, helper_not_dir, helper_access_denied }) catch unreachable); // A fixed template and three integers fit 256 bytes.
    if (step.first) {
        try out.appendSlice(allocator, " cat > \"$t\" || " ++ write_failed);
    } else {
        try out.appendSlice(allocator, " [ -f \"$t\" ] || exit " ++ std.fmt.comptimePrint("{d}", .{helper_failed}) ++
            "; cat >> \"$t\" || " ++ write_failed);
    }
    if (step.last) {
        try out.appendSlice(allocator, std.fmt.bufPrint(&buffer, "; chmod {o} -- \"$t\" && mv -f -- \"$t\" \"$p\" || ", .{step.mode & 0o7777}) catch unreachable); // A fixed template and one mode fit 256 bytes.
        try out.appendSlice(allocator, write_failed);
    }
    return out.toOwnedSlice(allocator);
}

/// Remove a write's temporary file after a failed step. Caller owns.
pub fn discardScript(allocator: Allocator, tmp: []const u8) QuoteError![]u8 {
    return pathScript(allocator, tmp, "rm -f -- \"$p\"");
}

/// Create a directory and its missing parents private and make the
/// directory itself 0700. A symbolic link in its place is refused, so the
/// directory Conduit names is one it made. Caller owns.
pub fn makePrivateDirScript(allocator: Allocator, path: []const u8) QuoteError![]u8 {
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer,
        \\umask 077; [ -L "$p" ] && exit {d}; mkdir -p -- "$p" 2>/dev/null; [ -d "$p" ] || {{ [ -e "$p" ] && exit {d}; exit {d}; }}; chmod 700 -- "$p" || exit {d}
    , .{ helper_failed, helper_not_dir, helper_access_denied, helper_access_denied }) catch unreachable; // A fixed template and four integers fit 512 bytes.
    return pathScript(allocator, path, body);
}

/// Print the remote user's state directory: an absolute `$XDG_STATE_HOME`,
/// else `$HOME/.local/state`, with no trailing newline; exit
/// `helper_not_found` when neither is absolute. The exec channel's
/// environment is sshd's plus whatever the login shell's non-interactive
/// startup files export.
pub const state_dir_script = std.fmt.comptimePrint(
    \\s=${{XDG_STATE_HOME:-}}; case "$s" in /*) ;; *) case "${{HOME:-}}" in /?*) s=$HOME/.local/state ;; *) exit {d} ;; esac ;; esac; printf '%s' "$s"
, .{helper_not_found});

/// Check `state_dir_script` output: one absolute path with no control bytes.
pub fn parseStateDir(output: []const u8) ?[]const u8 {
    if (output.len < 2 or output[0] != '/') return null;
    for (output) |byte| {
        if (byte < ' ' or byte == 0x7f) return null;
    }
    return output;
}

/// The hidden temporary a remote write of `path` stages into: beside the
/// destination, so the final `mv` is a rename within one directory, and
/// named per process and write so concurrent writers never share one.
pub fn writeTempPath(buffer: []u8, path: []const u8, process_id: i32, serial: u32) error{NoSpaceLeft}![]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return std.fmt.bufPrint(buffer, ".{s}.conduit-{d}-{d}", .{ path, process_id, serial });
    return std.fmt.bufPrint(buffer, "{s}/.{s}.conduit-{d}-{d}", .{ path[0..slash], path[slash + 1 ..], process_id, serial });
}

/// How often the remote watch loop fingerprints its directory, and how often
/// a watch whose channel ended tries to start a new one.
pub const watch_interval_s = 2;

/// Fingerprint a directory, print `r` once that baseline exists, then every
/// `watch_interval_s` seconds print `c` after a change and `h` otherwise. The
/// heartbeat makes the loop end (SIGPIPE) soon after its channel closes. A
/// missing directory fingerprints as empty, so its appearance is a change.
pub fn watchScript(allocator: Allocator, path: []const u8) QuoteError![]u8 {
    var body_buffer: [512]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buffer,
        \\fp() {{ (cd -- "$p" 2>/dev/null || exit 0; ls -lan --time-style=+%s.%N . 2>/dev/null || ls -lanT . 2>/dev/null || ls -lan .) 2>/dev/null | cksum; }}; prev=$(fp); echo r || exit 0; while :; do sleep {d}; cur=$(fp); if [ "$cur" != "$prev" ]; then prev=$cur; echo c || exit 0; else echo h || exit 0; fi; done
    , .{watch_interval_s}) catch unreachable; // A fixed template and one integer fit 512 bytes.
    return pathScript(allocator, path, body);
}

/// Parse `listDirScript` output, calling `visitor` per record until it
/// returns false. A malformed record ends the listing with `Unavailable`.
pub fn parseListing(output: []const u8, visitor: workspace.DirVisitor) workspace.FsError!void {
    var rest = output;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.Unavailable;
        const record = rest[0..end];
        rest = rest[end + 1 ..];
        if (record.len < 2) return error.Unavailable;
        const kind: workspace.PathKind = switch (record[0]) {
            'f' => .file,
            'd' => .directory,
            'o' => .other,
            else => return error.Unavailable,
        };
        if (!visitor.visit_fn(visitor.context, .{ .name = record[1..], .kind = kind })) return;
    }
}

/// Parse `statScript` output.
pub fn parseStat(output: []const u8) workspace.FsError!workspace.PathStat {
    const line = std.mem.trimEnd(u8, output, "\n");
    var fields = std.mem.splitScalar(u8, line, ' ');
    const kind_text = fields.next() orelse return error.Unavailable;
    const size_text = fields.next() orelse return error.Unavailable;
    const mtime_text = fields.next() orelse return error.Unavailable;
    if (fields.next() != null or kind_text.len != 1) return error.Unavailable;
    const kind: workspace.PathKind = switch (kind_text[0]) {
        'f' => .file,
        'd' => .directory,
        'o' => .other,
        else => return error.Unavailable,
    };
    const size = std.fmt.parseInt(u64, size_text, 10) catch return error.Unavailable;
    const dot = std.mem.indexOfScalar(u8, mtime_text, '.');
    const seconds_text = if (dot) |at| mtime_text[0..at] else mtime_text;
    const seconds = std.fmt.parseInt(i64, seconds_text, 10) catch return error.Unavailable;
    var nanos: i128 = 0;
    if (dot) |at| {
        const fraction = mtime_text[at + 1 ..];
        if (fraction.len == 0 or fraction.len > 9) return error.Unavailable;
        const value = std.fmt.parseInt(u32, fraction, 10) catch return error.Unavailable;
        nanos = value;
        var digits = fraction.len;
        while (digits < 9) : (digits += 1) nanos *= 10;
    }
    return .{ .kind = kind, .size = size, .mtime_ns = @as(i128, seconds) * std.time.ns_per_s + nanos };
}

/// Map a file helper's non-zero exit onto `FsError`.
fn helperError(exit_code: ?u8) workspace.FsError {
    return switch (exit_code orelse return error.Unavailable) {
        helper_not_found => error.NotFound,
        helper_is_dir => error.IsADirectory,
        helper_access_denied => error.AccessDenied,
        helper_not_dir => error.NotADirectory,
        else => error.Unavailable,
    };
}

fn fsFromRun(err: workspace.RunError) workspace.FsError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unavailable,
    };
}

pub const TargetError = error{ InvalidDestination, InvalidOption };

/// Check a destination before it reaches an argv: no option look-alike, no
/// whitespace or control bytes.
pub fn validateDestination(destination: []const u8) TargetError!void {
    if (destination.len == 0 or destination[0] == '-') return error.InvalidDestination;
    for (destination) |byte| {
        if (byte <= ' ' or byte == 0x7f) return error.InvalidDestination;
    }
}

/// Check one `Key=Value` client option.
pub fn validateOption(option: []const u8) TargetError!void {
    const eq = std.mem.indexOfScalar(u8, option, '=') orelse return error.InvalidOption;
    if (eq == 0 or option[0] == '-') return error.InvalidOption;
    for (option) |byte| {
        if (byte < ' ' or byte == 0x7f) return error.InvalidOption;
    }
}

/// Every command line the context runs, built from its fixed configuration.
/// Slices are borrowed; argv arrays and the strings this adds are allocated
/// from the caller's (normally arena) allocator.
pub const Invocation = struct {
    program: []const u8,
    destination: []const u8,
    port: ?u16 = null,
    config_file: ?[]const u8 = null,
    options: []const []const u8 = &.{},
    control_path: []const u8,

    /// What one argv needs between the program and the destination.
    const Mode = enum { master, session, exec, check, exit };

    fn build(self: Invocation, arena: Allocator, mode: Mode, remote_command: ?[]const u8) Allocator.Error![]const []const u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.append(arena, self.program);
        switch (mode) {
            .master => try argv.appendSlice(arena, &.{ "-M", "-N" }),
            .session => try argv.append(arena, "-tt"),
            .exec => try argv.append(arena, "-T"),
            .check, .exit => {},
        }
        // Conduit's lifecycle options first: OpenSSH keeps the first value it
        // sees, so neither the config file nor `options` can override them.
        try argv.appendSlice(arena, switch (mode) {
            .master => &.{ "-o", "ControlMaster=yes", "-o", "ControlPersist=no" },
            .session => &.{ "-o", "ControlMaster=no" },
            .exec => &.{ "-o", "BatchMode=yes", "-o", "ControlMaster=no" },
            .check, .exit => &.{ "-o", "BatchMode=yes" },
        });
        try argv.append(arena, "-o");
        try argv.append(arena, try std.fmt.allocPrint(arena, "ControlPath={s}", .{self.control_path}));
        if (mode == .master) {
            try argv.appendSlice(arena, &.{ "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3" });
        }
        if (self.config_file) |file| try argv.appendSlice(arena, &.{ "-F", file });
        if (self.port) |port| {
            try argv.append(arena, "-p");
            try argv.append(arena, try std.fmt.allocPrint(arena, "{d}", .{port}));
        }
        for (self.options) |option| try argv.appendSlice(arena, &.{ "-o", option });
        switch (mode) {
            .check => try argv.appendSlice(arena, &.{ "-O", "check" }),
            .exit => try argv.appendSlice(arena, &.{ "-O", "exit" }),
            else => {},
        }
        try argv.append(arena, "--");
        try argv.append(arena, self.destination);
        if (remote_command) |command| try argv.append(arena, command);
        return argv.toOwnedSlice(arena);
    }

    /// `ssh -M -N …`: the connection master, in its own PTY.
    pub fn masterArgv(self: Invocation, arena: Allocator) Allocator.Error![]const []const u8 {
        return self.build(arena, .master, null);
    }

    /// `ssh -tt …`: one interactive session over the master.
    pub fn sessionArgv(self: Invocation, arena: Allocator, remote_command: []const u8) Allocator.Error![]const []const u8 {
        return self.build(arena, .session, remote_command);
    }

    /// `ssh -T -o BatchMode=yes …`: one non-interactive exec channel.
    pub fn execArgv(self: Invocation, arena: Allocator, remote_command: []const u8) Allocator.Error![]const []const u8 {
        return self.build(arena, .exec, remote_command);
    }

    /// `ssh -O check`: is the master running?
    pub fn checkArgv(self: Invocation, arena: Allocator) Allocator.Error![]const []const u8 {
        return self.build(arena, .check, null);
    }

    /// `ssh -O exit`: ask the master to end.
    pub fn exitArgv(self: Invocation, arena: Allocator) Allocator.Error![]const []const u8 {
        return self.build(arena, .exit, null);
    }
};

pub const ControlDirError = error{
    /// A control directory exists but is a symlink, not a directory, not
    /// owned by this user, or not mode 0700.
    InsecureControlDir,
    ControlDirUnavailable,
    /// The socket path would not fit `sockaddr_un.sun_path`.
    ControlPathTooLong,
    Unsupported,
    OutOfMemory,
};

/// What `lstat` says about a candidate control directory.
pub const DirInfo = struct {
    is_dir: bool,
    is_symlink: bool,
    uid: u32,
    mode: u32,
};

/// Accept a control directory only if it is a real directory (not a
/// symlink), owned by `euid`, with mode exactly 0700.
pub fn validatePrivateDir(info: DirInfo, euid: u32) error{InsecureControlDir}!void {
    if (info.is_symlink or !info.is_dir) return error.InsecureControlDir;
    if (info.uid != euid) return error.InsecureControlDir;
    if (info.mode & 0o7777 != 0o700) return error.InsecureControlDir;
}

/// `sockaddr_un.sun_path`'s size on this target (108 on Linux).
pub const sun_path_len: usize = if (builtin.os.tag == .linux)
    @typeInfo(@FieldType(std.os.linux.sockaddr.un, "path")).array.len
else
    104;

/// OpenSSH binds the master's socket at `<ControlPath>.<16 random chars>`
/// and renames it into place, so that longer name must fit too, with its NUL.
pub const mux_bind_suffix_len: usize = 17;

/// Whether a socket path leaves room for OpenSSH's temporary bind name.
pub fn controlPathFits(path_len: usize) bool {
    return path_len + mux_bind_suffix_len + 1 <= sun_path_len;
}

/// Linux system calls this module needs and `std.Io` does not expose
/// (owner and mode without following links, raw mkdir, unix-socket probe).
const sys = struct {
    const linux = std.os.linux;

    fn euid() u32 {
        return linux.geteuid();
    }

    const MkdirResult = enum { created, exists, failed };

    fn mkdir(path: [:0]const u8, mode: u32) MkdirResult {
        const rc = linux.mkdir(path.ptr, mode);
        return switch (linux.errno(rc)) {
            .SUCCESS => .created,
            .EXIST => .exists,
            else => .failed,
        };
    }

    fn lstat(path: [:0]const u8) ?DirInfo {
        var buffer: linux.Statx = undefined;
        const rc = linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &buffer);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{
            .is_dir = linux.S.ISDIR(buffer.mode),
            .is_symlink = linux.S.ISLNK(buffer.mode),
            .uid = buffer.uid,
            .mode = buffer.mode,
        };
    }

    fn unlink(path: [:0]const u8) void {
        // A missing socket is the normal case; any other failure leaves a stale
        // name that the next master's bind replaces anyway.
        _ = linux.unlink(path.ptr);
    }

    /// Whether a unix socket at `path` accepts a connection right now.
    fn socketAccepts(path: [:0]const u8) bool {
        if (path.len >= sun_path_len) return false;
        const fd_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(fd_rc) != .SUCCESS) return false;
        const fd: i32 = @intCast(fd_rc);
        defer _ = linux.close(fd);
        var address: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
        @memcpy(address.path[0..path.len], path);
        const rc = linux.connect(fd, &address, @sizeOf(linux.sockaddr.un));
        return linux.errno(rc) == .SUCCESS;
    }

    fn setNonblocking(fd: i32) bool {
        const flags = linux.fcntl(fd, linux.F.GETFL, 0);
        if (linux.errno(flags) != .SUCCESS) return false;
        const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
        return linux.errno(linux.fcntl(fd, linux.F.SETFL, flags | nonblock)) == .SUCCESS;
    }

    const ReadResult = union(enum) { bytes: usize, would_block, end };

    fn readSome(fd: i32, buffer: []u8) ReadResult {
        const rc = linux.read(fd, buffer.ptr, buffer.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => if (rc == 0) .end else .{ .bytes = rc },
            .AGAIN, .INTR => .would_block,
            else => .end,
        };
    }

    fn pid() i32 {
        return linux.getpid();
    }

    /// Wait until `fd` is readable or hung up, for at most `timeout_ms`.
    fn waitReadable(fd: i32, timeout_ms: i32) bool {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&fds, 1, timeout_ms);
        return linux.errno(rc) == .SUCCESS and rc > 0;
    }
};

/// Create (or accept) one private directory level.
fn ensurePrivateDir(path: [:0]const u8) ControlDirError!void {
    switch (sys.mkdir(path, 0o700)) {
        .created, .exists => {},
        .failed => return error.ControlDirUnavailable,
    }
    const info = sys.lstat(path) orelse return error.ControlDirUnavailable;
    try validatePrivateDir(info, sys.euid());
}

/// Create and check the control directory: `<runtime_dir>/conduit/ssh`, or
/// `/tmp/conduit-<uid>/ssh`. Every level Conduit names is 0700, owned by this
/// user and not a symlink. Caller owns the returned path.
pub fn prepareControlDir(allocator: Allocator, runtime_dir: ?[]const u8) ControlDirError![:0]u8 {
    if (!supported) return error.Unsupported;
    const base = if (runtime_dir) |dir|
        try std.fmt.allocPrintSentinel(allocator, "{s}/conduit", .{dir}, 0)
    else
        try std.fmt.allocPrintSentinel(allocator, "/tmp/conduit-{d}", .{sys.euid()}, 0);
    defer allocator.free(base);
    try ensurePrivateDir(base);
    const dir = try std.fmt.allocPrintSentinel(allocator, "{s}/ssh", .{base}, 0);
    errdefer allocator.free(dir);
    try ensurePrivateDir(dir);
    return dir;
}

/// Distinguishes the masters of every SSH context in this process.
var next_socket_serial = std.atomic.Value(u32).init(0);

/// The socket path for a new context: a short per-process, per-context name,
/// so no hostname or user appears in the file system and two workspaces on
/// one host never share a master. Caller owns.
pub fn controlSocketPath(allocator: Allocator, dir: []const u8, process_id: i32, serial: u32) ControlDirError![:0]u8 {
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/m{d}-{d}", .{ dir, process_id, serial }, 0);
    if (!controlPathFits(path.len)) {
        allocator.free(path);
        return error.ControlPathTooLong;
    }
    return path;
}

pub const CreateError = Allocator.Error || TargetError || ControlDirError;
pub const ConnectError = pty.Error || error{AlreadyConnected};

/// The SSH `ExecutionContext` implementation. See the module comment.
pub const SshContext = struct {
    allocator: Allocator,
    io: std.Io,
    /// Owned copies of the target and options.
    destination: []u8,
    port: ?u16,
    config_file: ?[]u8,
    options: [][]u8,
    shell_integration: ShellIntegration,
    program: []u8,
    local_env: [][]u8,
    control_dir: [:0]u8,
    control_path: [:0]u8,
    wake: ?Wake,

    /// Owner thread only.
    machine: Machine = .{},
    master: ?pty.Pty = null,
    /// The master terminal's last size, reused by `reconnect`.
    master_size: pty.WindowSize = .{ .rows = 24, .cols = 80 },
    /// How the current master ended, once it has.
    master_exit: ?pty.ExitStatus = null,

    /// `machine.current` as workers see it.
    published: std.atomic.Value(State) = .init(.disconnected),
    /// Set by a worker that found the master gone; applied by `poll`.
    loss_reported: std.atomic.Value(bool) = .init(false),

    const vtable: ExecutionContext.VTable = .{
        .spawn = spawnFn,
        .kind = kindFn,
        .destroy = destroyFn,
        .read_file = readFileFn,
        .list_dir = listDirFn,
        .stat_path = statPathFn,
        .watch = watchFn,
        .run = runFn,
        .read_file_at = readFileAtFn,
        .write_file = writeFileFn,
        .make_private_dir = makePrivateDirFn,
        .state_dir = stateDirFn,
    };

    /// Allocate an owned, not yet connected SSH context. Validates the target
    /// and prepares the private control directory; starts no process.
    pub fn create(allocator: Allocator, io: std.Io, options: Options) CreateError!ExecutionContext {
        if (!supported) return error.Unsupported;
        try validateDestination(options.target.destination);
        for (options.target.options) |option| try validateOption(option);

        const self = try allocator.create(SshContext);
        errdefer allocator.destroy(self);
        const destination = try allocator.dupe(u8, options.target.destination);
        errdefer allocator.free(destination);
        const config_file = if (options.target.config_file) |file| try allocator.dupe(u8, file) else null;
        errdefer if (config_file) |file| allocator.free(file);
        const extra = try dupeList(allocator, options.target.options);
        errdefer freeList(allocator, extra);
        const program = try allocator.dupe(u8, options.ssh_program);
        errdefer allocator.free(program);
        const local_env = try dupeList(allocator, options.local_env);
        errdefer freeList(allocator, local_env);
        const control_dir = try prepareControlDir(allocator, options.runtime_dir);
        errdefer allocator.free(control_dir);
        const control_path = try controlSocketPath(allocator, control_dir, sys.pid(), next_socket_serial.fetchAdd(1, .monotonic));
        errdefer allocator.free(control_path);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .destination = destination,
            .port = options.target.port,
            .config_file = config_file,
            .options = extra,
            .shell_integration = options.target.shell_integration,
            .program = program,
            .local_env = local_env,
            .control_dir = control_dir,
            .control_path = control_path,
            .wake = options.wake,
        };
        if (self.shell_integration == .auto) {
            log.debug("remote shell integration is not implemented yet; starting remote shells without it", .{});
        }
        return ExecutionContext.initOwned(self, &vtable);
    }

    /// The SSH context behind an owned context, or null for any other kind.
    pub fn fromContext(context: *const ExecutionContext) ?*SshContext {
        if (context.vtable != &vtable) return null;
        return @ptrCast(@alignCast(context.ptr));
    }

    /// The SSH context behind a borrowed reference, or null.
    pub fn fromRef(ref: ExecutionContext.Ref) ?*SshContext {
        if (ref.vtable != &vtable) return null;
        return @ptrCast(@alignCast(ref.ptr));
    }

    /// The command lines this context runs.
    pub fn invocation(self: *const SshContext) Invocation {
        return .{
            .program = self.program,
            .destination = self.destination,
            .port = self.port,
            .config_file = self.config_file,
            .options = @ptrCast(self.options),
            .control_path = self.control_path,
        };
    }

    /// The published state; safe from any thread.
    pub fn state(self: *const SshContext) State {
        return self.published.load(.acquire);
    }

    /// The master's control socket path (no hostnames in it).
    pub fn controlPath(self: *const SshContext) []const u8 {
        return self.control_path;
    }

    /// Start the master in a new PTY of `size`. Owner thread. The state
    /// becomes `connecting`; `poll` reports `connected` once OpenSSH has
    /// authenticated (after any prompts the person answers in
    /// `masterTerminal`).
    pub fn connect(self: *SshContext, size: pty.WindowSize) ConnectError!void {
        if (self.master) |master| {
            if (master.state() == .running) return error.AlreadyConnected;
            master.destroy();
            self.master = null;
        }
        // A previous master of ours may have left its socket behind.
        sys.unlink(self.control_path);
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const argv = try self.invocation().masterArgv(arena_state.allocator());
        self.master = try pty.spawn(self.allocator, .{
            .argv = argv,
            .env = @ptrCast(self.local_env),
            .cwd = "",
            .size = size,
        });
        self.master_size = size;
        self.master_exit = null;
        self.machine.started();
        self.publish();
    }

    /// Advance the state from the master's process and control socket.
    /// Owner thread; non-blocking (one local socket probe while connecting).
    /// Call it on the owner's tick and whenever the master terminal has
    /// output.
    pub fn poll(self: *SshContext) State {
        if (self.loss_reported.swap(false, .acq_rel)) self.machine.checkFailed();
        if (self.master) |master| switch (master.state()) {
            .exited => |status| if (self.master_exit == null) {
                self.master_exit = status;
                self.machine.masterExited();
                log.debug("ssh master exited: {any}", .{status});
            },
            .running => if (self.machine.current == .connecting and sys.socketAccepts(self.control_path)) {
                self.machine.masterReady();
            },
        };
        self.publish();
        return self.machine.current;
    }

    /// Hang the connection up on purpose: `ssh -O exit`, then SIGHUP the
    /// master. Sessions over it end with 255; `sessionEnd` with
    /// `hung_up_by_conduit` classifies them. Owner thread; blocks for at most
    /// a few seconds on the local control command.
    pub fn disconnect(self: *SshContext) void {
        const master = self.master orelse return;
        if (master.state() != .running) return;
        self.machine.hangUp();
        self.publish();
        self.controlCommand(.exit);
        master.kill(.hangup) catch |err| log.debug("ssh master hangup: {s}", .{@errorName(err)});
    }

    /// Hang the connection up on purpose without waiting: SIGHUP the master,
    /// which ends it (`ControlPersist=no`) and with it every session over it.
    /// The non-blocking form of `disconnect` for the render thread, which
    /// must not wait on `ssh -O exit`. Owner thread.
    pub fn hangUp(self: *SshContext) void {
        const master = self.master orelse return;
        if (master.state() != .running) return;
        self.machine.hangUp();
        self.publish();
        master.kill(.hangup) catch |err| log.debug("ssh master hangup: {s}", .{@errorName(err)});
    }

    /// The copied destination this context connects to (an alias or
    /// `[user@]host`). Display data; never logged above debug.
    pub fn destinationText(self: *const SshContext) []const u8 {
        return self.destination;
    }

    /// The explicit port, when the target named one.
    pub fn portNumber(self: *const SshContext) ?u16 {
        return self.port;
    }

    /// Start a new master (after `lost`, `failed` or `disconnected`) at the
    /// last master terminal size. The owner respawns sessions once `poll`
    /// reports `connected` again. Owner thread.
    pub fn reconnect(self: *SshContext) ConnectError!void {
        if (self.master) |master| {
            if (master.state() == .running) {
                self.machine.hangUp();
                master.kill(.hangup) catch |err| log.debug("ssh master hangup: {s}", .{@errorName(err)});
            }
            master.destroy();
            self.master = null;
        }
        return self.connect(self.master_size);
    }

    /// Ask the master itself whether it is running (`ssh -O check`). Blocks
    /// on a local process: workers only. A negative answer while connected is
    /// reported as loss for the owner's next `poll`.
    pub fn checkMaster(self: *SshContext) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const argv = self.invocation().checkArgv(arena) catch return false;
        var result = workspace.runLocalProcess(arena, self.io, .{ .argv = argv, .cwd = "", .timeout_ms = 5000 }) catch return false;
        defer result.deinit(arena);
        const running = result.succeeded();
        if (!running and self.state() == .connected) self.reportLoss();
        return running;
    }

    /// A terminal view of the master's PTY for the owner to present as the
    /// connection session: OpenSSH's prompts appear there and keystrokes go
    /// to it. The context keeps owning the master; the view's `destroy` only
    /// lets go, and after `reconnect` the same view shows the new master. It
    /// must not outlive the context and is for the owner thread only.
    pub fn masterTerminal(self: *SshContext) pty.Pty {
        return .{ .ptr = self, .vtable = &master_view_vtable };
    }

    fn publish(self: *SshContext) void {
        const previous = self.published.swap(self.machine.current, .acq_rel);
        if (previous != self.machine.current) {
            log.info("ssh connection: {s} -> {s}", .{ @tagName(previous), @tagName(self.machine.current) });
        }
    }

    fn reportLoss(self: *SshContext) void {
        self.loss_reported.store(true, .release);
        if (self.wake) |hook| hook.wake_fn(hook.context);
    }

    fn controlCommand(self: *SshContext, which: enum { exit }) void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const argv = switch (which) {
            .exit => self.invocation().exitArgv(arena),
        } catch return;
        var result = workspace.runLocalProcess(arena, self.io, .{ .argv = argv, .cwd = "", .timeout_ms = 3000 }) catch |err| {
            log.debug("ssh -O {s}: {s}", .{ @tagName(which), @errorName(err) });
            return;
        };
        defer result.deinit(arena);
        log.debug("ssh -O {s}: exit {any}", .{ @tagName(which), result.exit_code });
    }

    /// Run one remote `/bin/sh` script over an exec channel. Refuses unless
    /// connected (a client with no master would open a direct connection).
    /// Exit 255 with the master gone is `Unavailable` and reported as loss;
    /// with the master alive it is the remote command's own status.
    fn runScript(
        self: *SshContext,
        allocator: Allocator,
        io: std.Io,
        script: []const u8,
        stdin: ?[]const u8,
        max_output: usize,
        timeout_ms: u32,
    ) workspace.RunError!workspace.RunResult {
        if (self.state() != .connected) return error.Unavailable;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const command = remoteCommand(arena, script) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.InvalidRequest,
        };
        const argv = try self.invocation().execArgv(arena, command);
        var result = workspace.runLocalProcess(allocator, io, .{
            .argv = argv,
            .cwd = "",
            .stdin = stdin,
            .max_output = max_output,
            .timeout_ms = timeout_ms,
        }) catch |err| return switch (err) {
            // The local client itself is missing or unusable.
            error.CommandNotFound, error.AccessDenied, error.SpawnFailed => error.Unavailable,
            else => |other| other,
        };
        if (result.exit_code == 255 and !sys.socketAccepts(self.control_path)) {
            result.deinit(allocator);
            self.reportLoss();
            return error.Unavailable;
        }
        return result;
    }

    fn fromPtr(ptr: *anyopaque) *SshContext {
        return @ptrCast(@alignCast(ptr));
    }

    fn spawnFn(ptr: *anyopaque, request: pty.SpawnRequest) pty.Error!pty.Pty {
        return fromPtr(ptr).spawnSession(request);
    }

    /// Start one interactive remote session. `request.argv` is the remote
    /// program (empty: the remote login shell), `request.cwd` a remote
    /// directory (empty: the remote home), `request.env` the remote overlay
    /// (variables naming this machine are dropped, see `crossesToRemote`),
    /// and `request.size` the local PTY's size, which the client forwards
    /// along with every resize. The local client gets `Options.local_env`.
    /// `error.Closed` while not connected.
    pub fn spawnSession(self: *SshContext, request: pty.SpawnRequest) pty.Error!pty.Pty {
        if (self.state() != .connected) return error.Closed;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const script = sessionScript(arena, request.cwd, request.env, request.argv) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.EmbeddedNul,
        };
        const command = remoteCommand(arena, script) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.EmbeddedNul,
        };
        const argv = try self.invocation().sessionArgv(arena, command);
        return pty.spawn(self.allocator, .{
            .argv = argv,
            .env = @ptrCast(self.local_env),
            .cwd = "",
            .size = request.size,
        });
    }

    fn kindFn(_: *const anyopaque) workspace.ExecutionContextKind {
        return .ssh;
    }

    fn destroyFn(ptr: *anyopaque) void {
        const self = fromPtr(ptr);
        if (self.master) |master| {
            if (master.state() == .running) {
                self.machine.hangUp();
                master.kill(.hangup) catch |err| log.debug("ssh master hangup: {s}", .{@errorName(err)});
            }
            master.destroy();
        }
        sys.unlink(self.control_path);
        const allocator = self.allocator;
        allocator.free(self.destination);
        if (self.config_file) |file| allocator.free(file);
        freeList(allocator, self.options);
        allocator.free(self.program);
        freeList(allocator, self.local_env);
        allocator.free(self.control_dir);
        allocator.free(self.control_path);
        allocator.destroy(self);
    }

    fn readFileFn(ptr: *anyopaque, io: std.Io, path: []const u8, buffer: []u8) workspace.FsError![]u8 {
        const self = fromPtr(ptr);
        const script = readFileScript(self.allocator, path, buffer.len + 1) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.NotFound,
        };
        defer self.allocator.free(script);
        var result = self.runScript(self.allocator, io, script, null, buffer.len + 1, 30_000) catch |err| return fsFromRun(err);
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return helperError(result.exit_code);
        if (result.stdout.len > buffer.len) return error.TooLarge;
        @memcpy(buffer[0..result.stdout.len], result.stdout);
        return buffer[0..result.stdout.len];
    }

    /// The most listing output kept, which bounds a remote directory to
    /// roughly as many entries as the Local watch fingerprints.
    const max_listing_bytes = 1024 * 1024;

    fn listDirFn(ptr: *anyopaque, io: std.Io, path: []const u8, visitor: workspace.DirVisitor) workspace.FsError!void {
        const self = fromPtr(ptr);
        const script = listDirScript(self.allocator, path) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.NotFound,
        };
        defer self.allocator.free(script);
        var result = self.runScript(self.allocator, io, script, null, max_listing_bytes, 30_000) catch |err| return fsFromRun(err);
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return helperError(result.exit_code);
        return parseListing(result.stdout, visitor);
    }

    fn statPathFn(ptr: *anyopaque, io: std.Io, path: []const u8) workspace.FsError!workspace.PathStat {
        const self = fromPtr(ptr);
        const script = statScript(self.allocator, path) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.NotFound,
        };
        defer self.allocator.free(script);
        var result = self.runScript(self.allocator, io, script, null, 4096, 30_000) catch |err| return fsFromRun(err);
        defer result.deinit(self.allocator);
        if (!result.succeeded()) return helperError(result.exit_code);
        return parseStat(result.stdout);
    }

    fn watchFn(ptr: *anyopaque, allocator: Allocator, io: std.Io, path: []const u8) workspace.WatchError!workspace.WatchHandle {
        return SshWatch.create(fromPtr(ptr), allocator, io, path);
    }

    fn runFn(ptr: *anyopaque, allocator: Allocator, io: std.Io, request: workspace.RunRequest) workspace.RunError!workspace.RunResult {
        const self = fromPtr(ptr);
        if (request.argv.len == 0) return error.InvalidRequest;
        if (request.stdin) |bytes| {
            if (bytes.len > workspace.RunRequest.max_stdin) return error.InvalidRequest;
        }
        const script = execScript(self.allocator, request.cwd, request.argv) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.InvalidRequest,
        };
        defer self.allocator.free(script);
        var result = try self.runScript(allocator, io, script, request.stdin, request.max_output, request.timeout_ms);
        if (result.exit_code == 127 and std.mem.endsWith(u8, result.stderr, not_found_marker ++ "\n")) {
            result.deinit(allocator);
            return error.CommandNotFound;
        }
        return result;
    }

    /// Run one file helper script and map a non-zero exit onto `FsError`.
    /// The caller owns the result.
    fn runHelper(self: *SshContext, io: std.Io, script: []const u8, stdin: ?[]const u8, max_output: usize) workspace.FsError!workspace.RunResult {
        var result = self.runScript(self.allocator, io, script, stdin, max_output, 30_000) catch |err| return fsFromRun(err);
        if (!result.succeeded()) {
            const err = helperError(result.exit_code);
            result.deinit(self.allocator);
            return err;
        }
        return result;
    }

    fn readFileAtFn(ptr: *anyopaque, io: std.Io, path: []const u8, offset: u64, buffer: []u8) workspace.FsError!usize {
        const self = fromPtr(ptr);
        if (buffer.len == 0) return 0;
        const script = readFileAtScript(self.allocator, path, offset, buffer.len) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.NotFound,
        };
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, buffer.len);
        defer result.deinit(self.allocator);
        // `head -c` never prints more than asked; anything else is not the helper.
        if (result.stdout.len > buffer.len) return error.Unavailable;
        @memcpy(buffer[0..result.stdout.len], result.stdout);
        return result.stdout.len;
    }

    /// Distinguishes the temporaries of concurrent remote writes.
    var next_write_serial = std.atomic.Value(u32).init(0);

    /// Stage `bytes` through `write_chunk_bytes`-sized exec channels into a
    /// hidden temporary beside `path`, then rename it into place on the last
    /// one (`writeFileScript`). A failed step removes the temporary.
    fn writeFileFn(ptr: *anyopaque, io: std.Io, path: []const u8, bytes: []const u8, mode: u32) workspace.FsError!void {
        const self = fromPtr(ptr);
        if (bytes.len > workspace.max_write_bytes) return error.TooLarge;
        var tmp_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = writeTempPath(&tmp_buffer, path, sys.pid(), next_write_serial.fetchAdd(1, .monotonic)) catch return error.NameTooLong;
        var offset: usize = 0;
        while (true) {
            const end = @min(bytes.len, offset + write_chunk_bytes);
            const step: WriteStep = .{ .first = offset == 0, .last = end == bytes.len, .mode = mode };
            self.writeStep(io, path, tmp, step, bytes[offset..end]) catch |err| {
                if (offset != 0) self.discard(io, tmp);
                return err;
            };
            if (step.last) return;
            offset = end;
        }
    }

    fn writeStep(self: *SshContext, io: std.Io, path: []const u8, tmp: []const u8, step: WriteStep, chunk: []const u8) workspace.FsError!void {
        const script = writeFileScript(self.allocator, path, tmp, step) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.NotFound,
        };
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, chunk, 4096);
        result.deinit(self.allocator);
    }

    /// Best effort: a temporary left by a lost connection is a hidden file in
    /// a private directory, removed with the sink.
    fn discard(self: *SshContext, io: std.Io, tmp: []const u8) void {
        const script = discardScript(self.allocator, tmp) catch return;
        defer self.allocator.free(script);
        var result = self.runHelper(io, script, null, 4096) catch |err| {
            log.debug("a remote write's temporary was not removed: {s}", .{@errorName(err)});
            return;
        };
        result.deinit(self.allocator);
    }

    fn makePrivateDirFn(ptr: *anyopaque, io: std.Io, path: []const u8) workspace.FsError!void {
        const self = fromPtr(ptr);
        const script = makePrivateDirScript(self.allocator, path) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.EmbeddedNul => error.NotFound,
        };
        defer self.allocator.free(script);
        var result = try self.runHelper(io, script, null, 4096);
        result.deinit(self.allocator);
    }

    fn stateDirFn(ptr: *anyopaque, io: std.Io, buffer: []u8) workspace.FsError![]u8 {
        const self = fromPtr(ptr);
        var result = try self.runHelper(io, state_dir_script, null, std.fs.max_path_bytes);
        defer result.deinit(self.allocator);
        const dir = parseStateDir(result.stdout) orelse return error.Unavailable;
        if (dir.len > buffer.len) return error.NameTooLong;
        @memcpy(buffer[0..dir.len], dir);
        return buffer[0..dir.len];
    }

    const master_view_vtable: pty.Pty.VTable = .{
        .write = viewWrite,
        .resize = viewResize,
        .kill = viewKill,
        .takeBytes = viewTakeBytes,
        .state = viewState,
        .waitReadable = viewWaitReadable,
        .destroy = viewDestroy,
    };

    fn viewWrite(ptr: *anyopaque, bytes: []const u8) pty.Error!usize {
        const master = fromPtr(ptr).master orelse return error.Closed;
        return master.write(bytes);
    }

    fn viewResize(ptr: *anyopaque, size: pty.WindowSize) pty.Error!void {
        const self = fromPtr(ptr);
        self.master_size = size;
        const master = self.master orelse return;
        return master.resize(size);
    }

    fn viewKill(ptr: *anyopaque, signal: pty.Signal) pty.Error!void {
        const master = fromPtr(ptr).master orelse return error.Closed;
        return master.kill(signal);
    }

    fn viewTakeBytes(ptr: *anyopaque, dest: []u8) usize {
        const master = fromPtr(ptr).master orelse return 0;
        return master.takeBytes(dest);
    }

    fn viewState(ptr: *anyopaque) pty.ChildState {
        const self = fromPtr(ptr);
        const master = self.master orelse return .{ .exited = self.master_exit orelse .unknown };
        return master.state();
    }

    fn viewWaitReadable(ptr: *anyopaque, timeout_ms: u32) bool {
        const master = fromPtr(ptr).master orelse return false;
        return master.waitReadable(timeout_ms);
    }

    fn viewDestroy(_: *anyopaque) void {}
};

/// The SSH `WatchHandle`: one long-lived exec channel running `watchScript`.
///
/// `create` blocks (at most `watch_ready_timeout_ms`) until the remote loop
/// has taken its baseline fingerprint, so a change made after `watch`
/// returns is never missed; afterwards `pollChanges` only reads what the
/// channel has already delivered and never blocks. When the channel ends
/// (connection lost, remote loop killed) the poll reports a change, because
/// one may have been missed, and a new channel is started at most every
/// `watch_interval_s` while the context is connected; that channel's own
/// baseline is again reported as a change, since anything may have changed
/// before it existed.
const SshWatch = struct {
    context: *SshContext,
    allocator: Allocator,
    io: std.Io,
    path: []u8,
    child: ?std.process.Child = null,
    /// Whether the current channel's baseline exists.
    ready: bool = false,
    last_start_ms: i64 = 0,

    const handle_vtable: workspace.WatchHandle.VTable = .{
        .poll_changes = pollChanges,
        .destroy = destroy,
    };

    fn create(context: *SshContext, allocator: Allocator, io: std.Io, path: []const u8) workspace.WatchError!workspace.WatchHandle {
        if (context.state() != .connected) return error.Unavailable;
        const self = try allocator.create(SshWatch);
        errdefer allocator.destroy(self);
        self.* = .{ .context = context, .allocator = allocator, .io = io, .path = try allocator.dupe(u8, path) };
        errdefer allocator.free(self.path);
        if (!self.start()) return error.Unavailable;
        errdefer self.stop();
        if (!self.awaitReady()) return error.Unavailable;
        return .{ .ptr = self, .vtable = &handle_vtable };
    }

    fn nowMs(io: std.Io) i64 {
        return std.Io.Clock.awake.now(io).toMilliseconds();
    }

    fn start(self: *SshWatch) bool {
        // The watch channel reads the child's pipe through the POSIX `sys` calls; SSH workspaces
        // are Linux-only (`supported`), and this keeps the rest of the module compiling elsewhere.
        if (comptime !supported) return false;
        self.last_start_ms = nowMs(self.io);
        self.ready = false;
        if (self.context.state() != .connected) return false;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const script = watchScript(arena, self.path) catch return false;
        const command = remoteCommand(arena, script) catch return false;
        const argv = self.context.invocation().execArgv(arena, command) catch return false;
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        }) catch |err| {
            log.debug("ssh watch channel: {s}", .{@errorName(err)});
            return false;
        };
        if (!sys.setNonblocking(child.stdout.?.handle)) {
            child.kill(self.io);
            return false;
        }
        self.child = child;
        return true;
    }

    fn stop(self: *SshWatch) void {
        if (self.child) |*child| child.kill(self.io);
        self.child = null;
        self.ready = false;
    }

    /// Block until the current channel reports its baseline, or fail.
    fn awaitReady(self: *SshWatch) bool {
        if (comptime !supported) return false;
        const deadline = nowMs(self.io) + watch_ready_timeout_ms;
        while (true) {
            const outcome = self.drain();
            if (self.ready) return true;
            if (outcome == .ended) return false;
            const remaining = deadline - nowMs(self.io);
            if (remaining <= 0) return false;
            const child = self.child orelse return false;
            _ = sys.waitReadable(child.stdout.?.handle, @intCast(remaining));
        }
    }

    const Drained = enum { quiet, changed, ended };

    /// Take everything the channel has delivered without blocking.
    fn drain(self: *SshWatch) Drained {
        if (comptime !supported) return .ended;
        const child = self.child orelse return .ended;
        var changed = false;
        var buffer: [256]u8 = undefined;
        while (true) {
            switch (sys.readSome(child.stdout.?.handle, &buffer)) {
                .bytes => |n| for (buffer[0..n]) |byte| switch (byte) {
                    'r' => self.ready = true,
                    'c' => changed = true,
                    else => {},
                },
                .would_block => return if (changed) .changed else .quiet,
                .end => {
                    self.stop();
                    return .ended;
                },
            }
        }
    }

    fn pollChanges(ptr: *anyopaque) bool {
        const self: *SshWatch = @ptrCast(@alignCast(ptr));
        if (self.child != null) {
            const was_ready = self.ready;
            return switch (self.drain()) {
                .changed, .ended => true,
                // A restarted channel's baseline: report what it may have missed.
                .quiet => !was_ready and self.ready,
            };
        }
        if (nowMs(self.io) - self.last_start_ms < watch_interval_s * std.time.ms_per_s) return false;
        _ = self.start();
        return false;
    }

    fn destroy(ptr: *anyopaque) void {
        const self: *SshWatch = @ptrCast(@alignCast(ptr));
        self.stop();
        const allocator = self.allocator;
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

/// How long `watch` waits for the remote loop's baseline.
pub const watch_ready_timeout_ms: i64 = 15_000;

fn dupeList(allocator: Allocator, items: []const []const u8) Allocator.Error![][]u8 {
    const list = try allocator.alloc([]u8, items.len);
    var filled: usize = 0;
    errdefer {
        for (list[0..filled]) |item| allocator.free(item);
        allocator.free(list);
    }
    for (items) |item| {
        list[filled] = try allocator.dupe(u8, item);
        filled += 1;
    }
    return list;
}

fn freeList(allocator: Allocator, list: [][]u8) void {
    for (list) |item| allocator.free(item);
    allocator.free(list);
}

// ---------------------------------------------------------------- unit tests

const testing = std.testing;

fn testInvocation() Invocation {
    return .{
        .program = "ssh",
        .destination = "dev-box",
        .port = 2222,
        .config_file = "/cfg/ssh_config",
        .options = &.{"IdentityFile=/k/id"},
        .control_path = "/run/user/1000/conduit/ssh/m42-0",
    };
}

fn expectArgv(expected: []const []const u8, actual: []const []const u8) !void {
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try testing.expectEqualStrings(want, got);
}

test "master, session, exec and control argv put Conduit's lifecycle options first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inv = testInvocation();

    try expectArgv(&.{
        "ssh",                   "-M",                     "-N",
        "-o",                    "ControlMaster=yes",      "-o",
        "ControlPersist=no",     "-o",                     "ControlPath=/run/user/1000/conduit/ssh/m42-0",
        "-o",                    "ServerAliveInterval=15", "-o",
        "ServerAliveCountMax=3", "-F",                     "/cfg/ssh_config",
        "-p",                    "2222",                   "-o",
        "IdentityFile=/k/id",    "--",                     "dev-box",
    }, try inv.masterArgv(arena));

    try expectArgv(&.{
        "ssh", "-tt",                                          "-o",     "ControlMaster=no",
        "-o",  "ControlPath=/run/user/1000/conduit/ssh/m42-0", "-F",     "/cfg/ssh_config",
        "-p",  "2222",                                         "-o",     "IdentityFile=/k/id",
        "--",  "dev-box",                                      "REMOTE",
    }, try inv.sessionArgv(arena, "REMOTE"));

    try expectArgv(&.{
        "ssh", "-T",                                           "-o", "BatchMode=yes",   "-o",  "ControlMaster=no",
        "-o",  "ControlPath=/run/user/1000/conduit/ssh/m42-0", "-F", "/cfg/ssh_config", "-p",  "2222",
        "-o",  "IdentityFile=/k/id",                           "--", "dev-box",         "CMD",
    }, try inv.execArgv(arena, "CMD"));

    try expectArgv(&.{
        "ssh",                "-o",              "BatchMode=yes", "-o",   "ControlPath=/run/user/1000/conduit/ssh/m42-0",
        "-F",                 "/cfg/ssh_config", "-p",            "2222", "-o",
        "IdentityFile=/k/id", "-O",              "check",         "--",   "dev-box",
    }, try inv.checkArgv(arena));

    // The production shape: no -F, no port, no extra options, so ~/.ssh/config decides.
    const plain: Invocation = .{ .program = "ssh", .destination = "me@host", .control_path = "/tmp/conduit-1/ssh/m1-0" };
    try expectArgv(&.{
        "ssh", "-o", "BatchMode=yes", "-o", "ControlPath=/tmp/conduit-1/ssh/m1-0", "-O", "exit", "--", "me@host",
    }, try plain.exitArgv(arena));

    // Never verbose, never a host-key policy of Conduit's own.
    for (try inv.masterArgv(arena)) |arg| {
        try testing.expect(!std.mem.eql(u8, arg, "-v"));
        try testing.expect(std.mem.indexOf(u8, arg, "StrictHostKeyChecking") == null);
    }
}

test "destinations and options that could become flags are refused" {
    try validateDestination("dev-box");
    try validateDestination("me@host.example");
    try validateDestination("[::1]");
    try testing.expectError(error.InvalidDestination, validateDestination(""));
    try testing.expectError(error.InvalidDestination, validateDestination("-oProxyCommand=evil"));
    try testing.expectError(error.InvalidDestination, validateDestination("host name"));
    try testing.expectError(error.InvalidDestination, validateDestination("host\nx"));
    try validateOption("IdentityFile=/k/id");
    try testing.expectError(error.InvalidOption, validateOption("NoEquals"));
    try testing.expectError(error.InvalidOption, validateOption("=x"));
    try testing.expectError(error.InvalidOption, validateOption("-F=x"));
    try testing.expectError(error.InvalidOption, validateOption("A=b\nc"));
}

test "single quoting neutralises quotes, expansions and newlines and refuses NUL" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try appendQuoted(&list, testing.allocator, "it's $(rm -rf ~) `x` \"y\"\nz");
    try testing.expectEqualStrings("'it'\\''s $(rm -rf ~) `x` \"y\"\nz'", list.items);
    list.clearRetainingCapacity();
    try appendQuoted(&list, testing.allocator, "");
    try testing.expectEqualStrings("''", list.items);
    try testing.expectError(error.EmbeddedNul, appendQuoted(&list, testing.allocator, "a\x00b"));
    try testing.expectError(error.EmbeddedNul, remoteCommand(testing.allocator, "a\x00b"));
}

test "session and exec scripts quote every value and keep only remote variables" {
    const script = try sessionScript(testing.allocator, "/srv/it's", &.{
        "TERM_PROGRAM=conduit",
        "HOME=/home/local",
        "PATH=/usr/bin",
        "SSH_AUTH_SOCK=/tmp/agent",
        "XDG_RUNTIME_DIR=/run/user/1",
        "BAD-KEY=x",
        "$(evil)=x",
        "PROBE=a'b",
    }, &.{ "vi", "+3", "--", "a b" });
    defer testing.allocator.free(script);
    try testing.expectEqualStrings(
        "cd -- '/srv/it'\\''s' 2>/dev/null || cd; export TERM_PROGRAM='conduit'; export PROBE='a'\\''b'; exec 'vi' '+3' '--' 'a b'",
        script,
    );

    const login = try sessionScript(testing.allocator, "", &.{}, &.{});
    defer testing.allocator.free(login);
    try testing.expectEqualStrings("exec \"${SHELL:-/bin/sh}\" -l", login);

    const exec = try execScript(testing.allocator, "/w", &.{ "git", "status" });
    defer testing.allocator.free(exec);
    try testing.expectEqualStrings(
        "cd -- '/w' 2>/dev/null || { printf '%s\\n' 'conduit-ssh: not found' >&2; exit 127; }; " ++
            "command -v 'git' >/dev/null 2>&1 || { printf '%s\\n' 'conduit-ssh: not found' >&2; exit 127; }; exec 'git' 'status'",
        exec,
    );
}

test "a remote command survives every login shell and decodes to the exact script" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const nasty = "it's $(echo pwned) `echo pwned` \"q\" \\ \\\\ %s %b \\0101 ! *\n\ttab \xc3\xbcn\xc3\xaf";
    var script: std.ArrayList(u8) = .empty;
    defer script.deinit(testing.allocator);
    try script.appendSlice(testing.allocator, "printf '%s' ");
    try appendQuoted(&script, testing.allocator, nasty);
    const command = try remoteCommand(testing.allocator, script.items);
    defer testing.allocator.free(command);
    // Nothing a login shell treats specially inside single quotes survives.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, command, "'"));
    try testing.expect(std.mem.indexOf(u8, command, "\\\\") == null);
    try testing.expect(std.mem.indexOfScalar(u8, command, '\n') == null);
    try testing.expect(std.mem.indexOfScalar(u8, command, '!') == null);

    // `ssh` hands the command to the login shell as `$SHELL -c <command>`.
    const shells = [_][]const u8{ "/bin/sh", "/bin/bash", "/bin/dash", "/usr/bin/zsh", "/usr/bin/fish", "/usr/bin/tcsh" };
    var tried: usize = 0;
    for (shells) |shell| {
        std.Io.Dir.cwd().access(testing.io, shell, .{}) catch continue;
        tried += 1;
        var result = try workspace.runLocalProcess(testing.allocator, testing.io, .{ .argv = &.{ shell, "-c", command }, .cwd = "/" });
        defer result.deinit(testing.allocator);
        testing.expectEqualStrings(nasty, result.stdout) catch |err| {
            std.debug.print("login shell {s} changed the command\n", .{shell});
            return err;
        };
    }
    try testing.expect(tried > 0);
}

test "listing and stat output parse, and malformed output is unavailable" {
    const Collect = struct {
        names: [4][]const u8 = undefined,
        kinds: [4]workspace.PathKind = undefined,
        count: usize = 0,
        limit: usize = 4,
        fn visit(ptr: *anyopaque, entry: workspace.DirEntry) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.names[self.count] = entry.name;
            self.kinds[self.count] = entry.kind;
            self.count += 1;
            return self.count < self.limit;
        }
    };
    var all: Collect = .{};
    try parseListing("fnotes.txt\x00dsub\x00oa\nb\x00", .{ .context = &all, .visit_fn = Collect.visit });
    try testing.expectEqual(@as(usize, 3), all.count);
    try testing.expectEqualStrings("notes.txt", all.names[0]);
    try testing.expectEqual(workspace.PathKind.directory, all.kinds[1]);
    try testing.expectEqualStrings("a\nb", all.names[2]);
    var bounded: Collect = .{ .limit = 1 };
    try parseListing("fa\x00fb\x00", .{ .context = &bounded, .visit_fn = Collect.visit });
    try testing.expectEqual(@as(usize, 1), bounded.count);
    var none: Collect = .{};
    try parseListing("", .{ .context = &none, .visit_fn = Collect.visit });
    try testing.expectError(error.Unavailable, parseListing("fa", .{ .context = &none, .visit_fn = Collect.visit }));
    try testing.expectError(error.Unavailable, parseListing("xa\x00", .{ .context = &none, .visit_fn = Collect.visit }));

    const gnu = try parseStat("f 17 1696712345.123456789\n");
    try testing.expectEqual(workspace.PathKind.file, gnu.kind);
    try testing.expectEqual(@as(u64, 17), gnu.size);
    try testing.expectEqual(@as(i128, 1696712345123456789), gnu.mtime_ns);
    const bsd = try parseStat("d 4096 1696712345\n");
    try testing.expectEqual(workspace.PathKind.directory, bsd.kind);
    try testing.expectEqual(@as(i128, 1696712345 * std.time.ns_per_s), bsd.mtime_ns);
    try testing.expectEqual(@as(i128, 1696712345500000000), (try parseStat("o 0 1696712345.5")).mtime_ns);
    try testing.expectError(error.Unavailable, parseStat("f x 1"));
    try testing.expectError(error.Unavailable, parseStat("f 1"));
    try testing.expectError(error.Unavailable, parseStat("q 1 1"));
    try testing.expectError(error.Unavailable, parseStat("f 1 1.1234567890"));

    try testing.expectEqual(error.NotFound, helperError(helper_not_found));
    try testing.expectEqual(error.IsADirectory, helperError(helper_is_dir));
    try testing.expectEqual(error.AccessDenied, helperError(helper_access_denied));
    try testing.expectEqual(error.NotADirectory, helperError(helper_not_dir));
    try testing.expectEqual(error.Unavailable, helperError(1));
    try testing.expectEqual(error.Unavailable, helperError(null));
}

test "the connection state machine tells a hang-up from a loss" {
    var machine: Machine = .{};
    try testing.expectEqual(State.disconnected, machine.current);
    machine.started();
    try testing.expectEqual(State.connecting, machine.current);
    machine.checkFailed();
    try testing.expectEqual(State.connecting, machine.current);
    machine.masterReady();
    try testing.expectEqual(State.connected, machine.current);
    machine.masterExited();
    try testing.expectEqual(State.lost, machine.current);

    // Exiting before ever connecting is a failure (wrong passphrase, refused key).
    machine.started();
    machine.masterExited();
    try testing.expectEqual(State.failed, machine.current);
    machine.masterReady();
    try testing.expectEqual(State.failed, machine.current);

    // A deliberate hang-up and its 255 exit stay disconnected.
    machine.started();
    machine.masterReady();
    machine.hangUp();
    machine.masterExited();
    machine.checkFailed();
    try testing.expectEqual(State.disconnected, machine.current);

    // A worker's failed check while connected is a loss; a reconnect clears the hang-up.
    machine.started();
    try testing.expect(!machine.hung_up);
    machine.masterReady();
    machine.checkFailed();
    try testing.expectEqual(State.lost, machine.current);

    try testing.expectEqual(SessionEnd.disconnected, sessionEnd(.{ .code = 255 }, false, false));
    try testing.expectEqual(SessionEnd.exited, sessionEnd(.{ .code = 255 }, true, false));
    try testing.expectEqual(SessionEnd.exited, sessionEnd(.{ .code = 255 }, false, true));
    try testing.expectEqual(SessionEnd.exited, sessionEnd(.{ .code = 0 }, false, false));
    try testing.expectEqual(SessionEnd.exited, sessionEnd(.{ .signal = .hangup }, false, false));
}

test "control directories must be private real directories and socket paths must fit" {
    try validatePrivateDir(.{ .is_dir = true, .is_symlink = false, .uid = 7, .mode = 0o40700 }, 7);
    try testing.expectError(error.InsecureControlDir, validatePrivateDir(.{ .is_dir = true, .is_symlink = false, .uid = 7, .mode = 0o40755 }, 7));
    try testing.expectError(error.InsecureControlDir, validatePrivateDir(.{ .is_dir = true, .is_symlink = false, .uid = 8, .mode = 0o40700 }, 7));
    try testing.expectError(error.InsecureControlDir, validatePrivateDir(.{ .is_dir = false, .is_symlink = true, .uid = 7, .mode = 0o120777 }, 7));
    try testing.expectError(error.InsecureControlDir, validatePrivateDir(.{ .is_dir = false, .is_symlink = false, .uid = 7, .mode = 0o100700 }, 7));

    try testing.expect(controlPathFits(sun_path_len - mux_bind_suffix_len - 1));
    try testing.expect(!controlPathFits(sun_path_len - mux_bind_suffix_len));
    const long_dir = "/" ++ "d" ** 100;
    try testing.expectError(error.ControlPathTooLong, controlSocketPath(testing.allocator, long_dir, 1, 0));
    const path = try controlSocketPath(testing.allocator, "/run/user/1000/conduit/ssh", 4242, 3);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings("/run/user/1000/conduit/ssh/m4242-3", path);
}

/// The absolute path of a testing temporary directory.
fn tmpRoot(tmp: *std.testing.TmpDir) ![:0]u8 {
    var relative: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&relative, ".zig-cache/tmp/{s}", .{tmp.sub_path[0..]});
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, path, testing.allocator);
}

test "the control directory is created 0700 and an insecure or symlinked one is refused" {
    if (!supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp);
    defer testing.allocator.free(root);

    // Fresh: both levels are created private, and reuse is accepted.
    try tmp.dir.createDir(testing.io, "fresh", .default_dir);
    const fresh_root = try std.fmt.allocPrint(testing.allocator, "{s}/fresh", .{root});
    defer testing.allocator.free(fresh_root);
    const dir = try prepareControlDir(testing.allocator, fresh_root);
    defer testing.allocator.free(dir);
    const info = sys.lstat(dir).?;
    try testing.expect(info.is_dir);
    try testing.expectEqual(@as(u32, 0o700), info.mode & 0o7777);
    const again = try prepareControlDir(testing.allocator, fresh_root);
    testing.allocator.free(again);

    // A group-readable level is refused.
    try tmp.dir.createDirPath(testing.io, "open/conduit");
    const open_conduit = try std.fmt.allocPrintSentinel(testing.allocator, "{s}/open/conduit", .{root}, 0);
    defer testing.allocator.free(open_conduit);
    try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.chmod(open_conduit.ptr, 0o755)));
    const open_root = try std.fmt.allocPrint(testing.allocator, "{s}/open", .{root});
    defer testing.allocator.free(open_root);
    try testing.expectError(error.InsecureControlDir, prepareControlDir(testing.allocator, open_root));

    // A symlink, even to a private directory, is refused.
    try tmp.dir.createDir(testing.io, "linked", .default_dir);
    const private_target = try std.fmt.allocPrint(testing.allocator, "{s}/fresh/conduit", .{root});
    defer testing.allocator.free(private_target);
    try tmp.dir.symLink(testing.io, private_target, "linked/conduit", .{ .is_directory = true });
    const linked_root = try std.fmt.allocPrint(testing.allocator, "{s}/linked", .{root});
    defer testing.allocator.free(linked_root);
    try testing.expectError(error.InsecureControlDir, prepareControlDir(testing.allocator, linked_root));
}

/// Run a helper script the way the remote side does: the `remoteCommand`
/// wrapper parsed by a POSIX shell, with `prefix` (an `env` invocation) in
/// front. Caller owns the result.
fn runHelperLocally(prefix: []const []const u8, script: []const u8, stdin: ?[]const u8) !workspace.RunResult {
    const command = try remoteCommand(testing.allocator, script);
    defer testing.allocator.free(command);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.appendSlice(testing.allocator, prefix);
    try argv.appendSlice(testing.allocator, &.{ "/bin/sh", "-c", command });
    return workspace.runLocalProcess(testing.allocator, testing.io, .{ .argv = argv.items, .cwd = "", .stdin = stdin });
}

fn localMode(path: [:0]const u8) !u32 {
    var buffer: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(std.os.linux.AT.FDCWD, path.ptr, 0, .{ .MODE = true }, &buffer);
    if (std.os.linux.errno(rc) != .SUCCESS) return error.StatFailed;
    return buffer.mode & 0o7777;
}

test "the write, offset-read, private-directory and state-directory helpers do what they say under /bin/sh" {
    if (!supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmpRoot(&tmp);
    defer testing.allocator.free(root);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A three-step write into missing parents: nothing appears until the last
    // step renames the temporary, then the bytes and mode are exact.
    const dest = try std.fmt.allocPrintSentinel(arena, "{s}/sink/it's $(x)/hook.sh", .{root}, 0);
    var tmp_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const temporary = try writeTempPath(&tmp_buffer, dest, 42, 7);
    try testing.expect(std.mem.endsWith(u8, temporary, "/sink/it's $(x)/.hook.sh.conduit-42-7"));
    const steps = [_]struct { step: WriteStep, chunk: []const u8 }{
        .{ .step = .{ .first = true, .last = false, .mode = 0o700 }, .chunk = "#!/bin/sh\n" },
        .{ .step = .{ .first = false, .last = false, .mode = 0o700 }, .chunk = "echo 'a\\b'\n" },
        .{ .step = .{ .first = false, .last = true, .mode = 0o700 }, .chunk = "exit 0\n" },
    };
    for (steps) |entry| {
        try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, dest, .{}));
        const script = try writeFileScript(arena, dest, temporary, entry.step);
        var result = try runHelperLocally(&.{}, script, entry.chunk);
        defer result.deinit(testing.allocator);
        try testing.expect(result.succeeded());
    }
    var read_buffer: [128]u8 = undefined;
    try testing.expectEqualStrings("#!/bin/sh\necho 'a\\b'\nexit 0\n", try std.Io.Dir.cwd().readFile(testing.io, dest, &read_buffer));
    try testing.expectEqual(@as(u32, 0o700), try localMode(dest));
    const parent = try std.fmt.allocPrintSentinel(arena, "{s}/sink", .{root}, 0);
    try testing.expectEqual(@as(u32, 0o700), try localMode(parent));
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(testing.io, temporary, .{}));

    // A single-step rewrite replaces the file; an append without its first
    // step fails; a directory destination is refused, not moved into.
    {
        var result = try runHelperLocally(&.{}, try writeFileScript(arena, dest, temporary, .{ .first = true, .last = true, .mode = 0o600 }), "allow");
        defer result.deinit(testing.allocator);
        try testing.expect(result.succeeded());
        try testing.expectEqualStrings("allow", try std.Io.Dir.cwd().readFile(testing.io, dest, &read_buffer));
        try testing.expectEqual(@as(u32, 0o600), try localMode(dest));
    }
    {
        var result = try runHelperLocally(&.{}, try writeFileScript(arena, dest, temporary, .{ .first = false, .last = true, .mode = 0o600 }), "x");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(?u8, helper_failed), result.exit_code);
    }
    {
        var result = try runHelperLocally(&.{}, try writeFileScript(arena, parent, temporary, .{ .first = true, .last = true, .mode = 0o600 }), "x");
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(?u8, helper_is_dir), result.exit_code);
    }

    // Offset reads follow an append-only file.
    {
        try tmp.dir.writeFile(testing.io, .{ .sub_path = "events.jsonl", .data = "one\ntwo\n" });
        const events = try std.fmt.allocPrint(arena, "{s}/events.jsonl", .{root});
        var result = try runHelperLocally(&.{}, try readFileAtScript(arena, events, 4, 3), null);
        defer result.deinit(testing.allocator);
        try testing.expect(result.succeeded());
        try testing.expectEqualStrings("two", result.stdout);
        var past = try runHelperLocally(&.{}, try readFileAtScript(arena, events, 100, 3), null);
        defer past.deinit(testing.allocator);
        try testing.expect(past.succeeded());
        try testing.expectEqualStrings("", past.stdout);
        var absent = try runHelperLocally(&.{}, try readFileAtScript(arena, try std.fmt.allocPrint(arena, "{s}/absent", .{root}), 0, 3), null);
        defer absent.deinit(testing.allocator);
        try testing.expectEqual(@as(?u8, helper_not_found), absent.exit_code);
    }

    // A private directory: created with its parents, an existing one
    // tightened, a symlink refused.
    {
        const deep = try std.fmt.allocPrintSentinel(arena, "{s}/state/conduit/agents/r/a", .{root}, 0);
        var result = try runHelperLocally(&.{}, try makePrivateDirScript(arena, deep), null);
        defer result.deinit(testing.allocator);
        try testing.expect(result.succeeded());
        try testing.expectEqual(@as(u32, 0o700), try localMode(deep));
        const middle = try std.fmt.allocPrintSentinel(arena, "{s}/state/conduit", .{root}, 0);
        try testing.expectEqual(@as(u32, 0o700), try localMode(middle));
        try testing.expectEqual(std.os.linux.E.SUCCESS, std.os.linux.errno(std.os.linux.chmod(deep.ptr, 0o755)));
        var again = try runHelperLocally(&.{}, try makePrivateDirScript(arena, deep), null);
        defer again.deinit(testing.allocator);
        try testing.expect(again.succeeded());
        try testing.expectEqual(@as(u32, 0o700), try localMode(deep));
        try tmp.dir.symLink(testing.io, deep, "linked", .{ .is_directory = true });
        var linked = try runHelperLocally(&.{}, try makePrivateDirScript(arena, try std.fmt.allocPrint(arena, "{s}/linked", .{root})), null);
        defer linked.deinit(testing.allocator);
        try testing.expectEqual(@as(?u8, helper_failed), linked.exit_code);
    }

    // The state directory comes from an absolute XDG_STATE_HOME, else HOME.
    {
        var xdg = try runHelperLocally(&.{ "env", "XDG_STATE_HOME=/x/state", "HOME=/h" }, state_dir_script, null);
        defer xdg.deinit(testing.allocator);
        try testing.expectEqualStrings("/x/state", parseStateDir(xdg.stdout).?);
        var relative = try runHelperLocally(&.{ "env", "XDG_STATE_HOME=state", "HOME=/h" }, state_dir_script, null);
        defer relative.deinit(testing.allocator);
        try testing.expectEqualStrings("/h/.local/state", parseStateDir(relative.stdout).?);
        var none = try runHelperLocally(&.{ "env", "-u", "XDG_STATE_HOME", "-u", "HOME" }, state_dir_script, null);
        defer none.deinit(testing.allocator);
        try testing.expectEqual(@as(?u8, helper_not_found), none.exit_code);
    }
    try testing.expect(parseStateDir("relative") == null);
    try testing.expect(parseStateDir("/a\nb") == null);
}

// ------------------------------------------------- sshd container integration

/// A terminal under test: everything its child printed, and bounded waits on
/// it. The waits block in `waitReadable`, never in a sleep.
const TestTerminal = struct {
    handle: pty.Pty,
    seen: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestTerminal) void {
        self.seen.deinit(testing.allocator);
    }

    fn pump(self: *TestTerminal) !void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = self.handle.takeBytes(&buffer);
            if (n == 0) return;
            try self.seen.appendSlice(testing.allocator, buffer[0..n]);
        }
    }

    fn send(self: *TestTerminal, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) rest = rest[try self.handle.write(rest)..];
    }

    /// Wait for `needle` in what arrived after offset `from`.
    fn waitFor(self: *TestTerminal, from: usize, needle: []const u8, timeout_ms: i64) !void {
        const deadline = testNowMs() + timeout_ms;
        while (true) {
            try self.pump();
            if (std.mem.indexOfPos(u8, self.seen.items, from, needle) != null) return;
            if (self.handle.state() != .running) {
                try self.pump();
                if (std.mem.indexOfPos(u8, self.seen.items, from, needle) != null) return;
                std.debug.print("terminal ended before {s}\n", .{needle});
                return error.EndedEarly;
            }
            if (testNowMs() > deadline) {
                std.debug.print("timed out waiting for {s}\n", .{needle});
                return error.Timeout;
            }
            _ = self.handle.waitReadable(100);
        }
    }

    fn waitExit(self: *TestTerminal, timeout_ms: i64) !pty.ExitStatus {
        const deadline = testNowMs() + timeout_ms;
        while (true) {
            try self.pump();
            switch (self.handle.state()) {
                .exited => |status| return status,
                .running => {},
            }
            if (testNowMs() > deadline) return error.Timeout;
            _ = self.handle.waitReadable(100);
        }
    }
};

fn testNowMs() i64 {
    return std.Io.Clock.awake.now(testing.io).toMilliseconds();
}

/// Run a local helper command (docker, ssh-keygen) to completion.
fn hostCommand(argv: []const []const u8, timeout_ms: u32) !workspace.RunResult {
    return workspace.runLocalProcess(testing.allocator, testing.io, .{
        .argv = argv,
        .cwd = "",
        .timeout_ms = timeout_ms,
        .max_output = 4 * 1024 * 1024,
    });
}

/// Poll the context until it reports `want`, waiting on the master terminal.
fn waitState(context: *SshContext, master: *TestTerminal, want: State, timeout_ms: i64) !void {
    const deadline = testNowMs() + timeout_ms;
    while (true) {
        try master.pump();
        const current = context.poll();
        if (current == want) return;
        if (current == .failed) {
            std.debug.print("master failed while waiting for {s}\n", .{@tagName(want)});
            return error.MasterFailed;
        }
        if (testNowMs() > deadline) {
            std.debug.print("timed out in {s} waiting for {s}\n", .{ @tagName(current), @tagName(want) });
            return error.Timeout;
        }
        _ = master.handle.waitReadable(100);
    }
}

/// How many times sshd has accepted a public key so far.
fn acceptedAuthentications(container: []const u8) !usize {
    var logs = try hostCommand(&.{ "docker", "logs", container }, 30_000);
    defer logs.deinit(testing.allocator);
    return std.mem.count(u8, logs.stdout, "Accepted publickey") + std.mem.count(u8, logs.stderr, "Accepted publickey");
}

const image = "conduit-ssh-test:latest";
const remote_project = "/home/conduit/project";

/// Test support for other modules' integration tests (the agent adapters,
/// TASK-61): a disposable sshd container from `test/fixtures/ssh` and a
/// connected `SshContext` to it. Only tests may use it: it relies on
/// `std.testing` and Docker. The key is a throwaway unencrypted one and the
/// private client config accepts the container's new host key, so the master
/// connects without prompts; the prompts themselves are covered by this
/// file's own integration test.
pub const TestRemote = struct {
    tmp: std.testing.TmpDir,
    work: [:0]u8,
    container: []u8,
    runtime_dir: [:0]u8,
    owner: ExecutionContext,
    master: TestTerminal,

    /// The remote user's home and the project fixture inside it.
    pub const home = "/home/conduit";
    pub const project = remote_project;

    /// Start the container and connect; null when Docker or the image is
    /// unavailable, so the caller skips. The result is heap-allocated
    /// because the master terminal points into it.
    pub fn start() !?*TestRemote {
        if (!supported) return null;
        var info = hostCommand(&.{ "docker", "info" }, 30_000) catch return null;
        const docker_ok = info.succeeded();
        info.deinit(testing.allocator);
        if (!docker_ok) return null;
        var build = hostCommand(&.{ "docker", "build", "-q", "-t", image, "test/fixtures/ssh" }, 900_000) catch return null;
        const built = build.succeeded();
        build.deinit(testing.allocator);
        if (!built) return null;

        const self = try testing.allocator.create(TestRemote);
        errdefer testing.allocator.destroy(self);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.work = try tmpRoot(&self.tmp);
        errdefer testing.allocator.free(self.work);

        const serial = next_socket_serial.fetchAdd(1, .monotonic);
        const key = try std.fmt.allocPrint(testing.allocator, "{s}/id_ed25519", .{self.work});
        defer testing.allocator.free(key);
        var keygen = try hostCommand(&.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "conduit-ssh-test", "-f", key }, 30_000);
        defer keygen.deinit(testing.allocator);
        if (!keygen.succeeded()) return error.KeygenFailed;

        self.container = try std.fmt.allocPrint(testing.allocator, "conduit-ssh-agent-{d}-{d}-{d}", .{ sys.pid(), serial, testNowMs() });
        errdefer testing.allocator.free(self.container);
        const mount = try std.fmt.allocPrint(testing.allocator, "{s}.pub:/conduit-key.pub:ro", .{key});
        defer testing.allocator.free(mount);
        var started = try hostCommand(&.{ "docker", "run", "-d", "--name", self.container, "-p", "127.0.0.1::22", "-v", mount, image }, 60_000);
        defer started.deinit(testing.allocator);
        if (!started.succeeded()) return error.ContainerFailed;
        errdefer {
            var removed = hostCommand(&.{ "docker", "rm", "-f", self.container }, 60_000) catch null;
            if (removed) |*result| result.deinit(testing.allocator);
        }

        var port_result = try hostCommand(&.{ "docker", "port", self.container, "22/tcp" }, 30_000);
        defer port_result.deinit(testing.allocator);
        const first_line = std.mem.sliceTo(port_result.stdout, '\n');
        const port_text = first_line[(std.mem.lastIndexOfScalar(u8, first_line, ':') orelse return error.NoPort) + 1 ..];
        const port = try std.fmt.parseInt(u16, port_text, 10);
        {
            const deadline = testNowMs() + 30_000;
            while (true) {
                var logs = try hostCommand(&.{ "docker", "logs", self.container }, 30_000);
                defer logs.deinit(testing.allocator);
                if (std.mem.indexOf(u8, logs.stderr, "Server listening") != null or
                    std.mem.indexOf(u8, logs.stdout, "Server listening") != null) break;
                if (testNowMs() > deadline) return error.SshdNeverListened;
            }
        }

        const config_text = try std.fmt.allocPrint(testing.allocator,
            \\Host conduit-test-host
            \\  HostName 127.0.0.1
            \\  Port {d}
            \\  User conduit
            \\  IdentityFile {s}
            \\  IdentitiesOnly yes
            \\  IdentityAgent none
            \\  UserKnownHostsFile {s}/known_hosts
            \\  GlobalKnownHostsFile /dev/null
            \\  StrictHostKeyChecking accept-new
            \\  UpdateHostKeys no
            \\
        , .{ port, key, self.work });
        defer testing.allocator.free(config_text);
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "ssh_config", .data = config_text });
        const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/ssh_config", .{self.work});
        defer testing.allocator.free(config_path);

        self.runtime_dir = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/conduit-ssh-agent-{d}-{d}", .{ sys.pid(), serial }, 0);
        errdefer testing.allocator.free(self.runtime_dir);
        if (sys.mkdir(self.runtime_dir, 0o700) == .failed) return error.RuntimeDirFailed;
        errdefer std.Io.Dir.cwd().deleteTree(testing.io, self.runtime_dir) catch {}; // Best-effort cleanup of a private test directory.

        const path_entry = try std.fmt.allocPrint(testing.allocator, "PATH={s}", .{testing.environ.getPosix("PATH") orelse "/usr/bin:/bin"});
        defer testing.allocator.free(path_entry);
        self.owner = try SshContext.create(testing.allocator, testing.io, .{
            .target = .{ .destination = "conduit-test-host", .config_file = config_path },
            .local_env = &.{ path_entry, "TERM=xterm-256color", "LANG=C.UTF-8" },
            .runtime_dir = self.runtime_dir,
        });
        errdefer self.owner.deinit();
        const context = SshContext.fromContext(&self.owner).?;
        self.master = .{ .handle = context.masterTerminal() };
        errdefer self.master.deinit();
        try context.connect(.{ .rows = 24, .cols = 100 });
        try waitState(context, &self.master, .connected, 30_000);
        return self;
    }

    /// The connected context, borrowed.
    pub fn ref(self: *TestRemote) ExecutionContext.Ref {
        return self.owner.borrow();
    }

    /// Run one remote command and return its result; the caller deinits it.
    pub fn run(self: *TestRemote, argv: []const []const u8, stdin: ?[]const u8) !workspace.RunResult {
        return self.ref().run(testing.allocator, testing.io, .{ .argv = argv, .cwd = "", .stdin = stdin, .timeout_ms = 60_000 });
    }

    pub fn stop(self: *TestRemote) void {
        self.owner.deinit();
        self.master.deinit();
        var removed = hostCommand(&.{ "docker", "rm", "-f", self.container }, 60_000) catch null;
        if (removed) |*result| result.deinit(testing.allocator);
        std.Io.Dir.cwd().deleteTree(testing.io, self.runtime_dir) catch {}; // Best-effort cleanup of a private test directory.
        testing.allocator.free(self.runtime_dir);
        testing.allocator.free(self.container);
        testing.allocator.free(self.work);
        self.tmp.cleanup();
        testing.allocator.destroy(self);
    }
};

test "remote writes, offset reads, private directories and the state directory work over the master" {
    const remote = (try TestRemote.start()) orelse return error.SkipZigTest;
    defer remote.stop();
    const ref = remote.ref();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state = try ref.stateDir(testing.io, &buffer);
    try testing.expectEqualStrings(TestRemote.home ++ "/.local/state", state);

    const sink = TestRemote.home ++ "/.local/state/conduit/agents/run/agent";
    try ref.makePrivateDir(testing.io, sink);
    var mode = try remote.run(&.{ "stat", "-c", "%a", TestRemote.home ++ "/.local/state/conduit", sink }, null);
    defer mode.deinit(testing.allocator);
    try testing.expectEqualStrings("700\n700\n", mode.stdout);

    // A write larger than one chunk arrives whole, with its mode, and leaves
    // no temporary behind.
    const big = try testing.allocator.alloc(u8, write_chunk_bytes * 2 + 123);
    defer testing.allocator.free(big);
    for (big, 0..) |*byte, i| byte.* = @intCast(i % 251);
    try ref.writeFile(testing.io, sink ++ "/blob", big, 0o600);
    const back = try testing.allocator.alloc(u8, big.len);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, big, try ref.readFile(testing.io, sink ++ "/blob", back));
    try testing.expectEqual(big.len - 1000, try ref.readFileAt(testing.io, sink ++ "/blob", 1000, back));
    try testing.expectEqualSlices(u8, big[1000..], back[0 .. big.len - 1000]);
    var listing = try remote.run(&.{ "sh", "-c", "ls -A \"$0\"; stat -c %a \"$0/blob\"", sink }, null);
    defer listing.deinit(testing.allocator);
    try testing.expectEqualStrings("blob\n600\n", listing.stdout);

    try testing.expectError(error.IsADirectory, ref.writeFile(testing.io, sink, "x", 0o600));
    try testing.expectError(error.NotFound, ref.readFileAt(testing.io, sink ++ "/absent", 0, back));
    try testing.expectEqual(@as(usize, 0), try ref.readFileAt(testing.io, sink ++ "/blob", big.len, back));
}

test "an SSH context carries shells, files and commands over one authenticated master, detects loss and reconnects" {
    if (!supported) return error.SkipZigTest;
    // Docker and the system OpenSSH client are prerequisites; without them the
    // test is skipped rather than failed.
    var info = hostCommand(&.{ "docker", "info" }, 30_000) catch return error.SkipZigTest;
    const docker_ok = info.succeeded();
    info.deinit(testing.allocator);
    if (!docker_ok) return error.SkipZigTest;
    var build = hostCommand(&.{ "docker", "build", "-q", "-t", image, "test/fixtures/ssh" }, 900_000) catch return error.SkipZigTest;
    const built = build.succeeded();
    build.deinit(testing.allocator);
    if (!built) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const work = try tmpRoot(&tmp);
    defer testing.allocator.free(work);

    // A throwaway key with a throwaway passphrase, so the master must show
    // OpenSSH's own passphrase prompt. Never the user's ~/.ssh or agent.
    var pid_buffer: [32]u8 = undefined;
    const tag = try std.fmt.bufPrint(&pid_buffer, "{d}", .{sys.pid()});
    const passphrase = try std.fmt.allocPrint(testing.allocator, "conduit-test-{s}-{d}", .{ tag, testNowMs() });
    defer testing.allocator.free(passphrase);
    const key = try std.fmt.allocPrint(testing.allocator, "{s}/id_ed25519", .{work});
    defer testing.allocator.free(key);
    var keygen = try hostCommand(&.{ "ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-C", "conduit-ssh-test", "-f", key }, 30_000);
    defer keygen.deinit(testing.allocator);
    try testing.expect(keygen.succeeded());

    const container = try std.fmt.allocPrint(testing.allocator, "conduit-ssh-test-{s}-{d}", .{ tag, testNowMs() });
    defer testing.allocator.free(container);
    const mount = try std.fmt.allocPrint(testing.allocator, "{s}.pub:/conduit-key.pub:ro", .{key});
    defer testing.allocator.free(mount);
    var started = try hostCommand(&.{ "docker", "run", "-d", "--name", container, "-p", "127.0.0.1::22", "-v", mount, image }, 60_000);
    defer started.deinit(testing.allocator);
    try testing.expect(started.succeeded());
    defer {
        var removed = hostCommand(&.{ "docker", "rm", "-f", container }, 60_000) catch null;
        if (removed) |*result| result.deinit(testing.allocator);
    }

    var port_result = try hostCommand(&.{ "docker", "port", container, "22/tcp" }, 30_000);
    defer port_result.deinit(testing.allocator);
    const first_line = std.mem.sliceTo(port_result.stdout, '\n');
    const port_text = first_line[(std.mem.lastIndexOfScalar(u8, first_line, ':') orelse return error.NoPort) + 1 ..];
    const port = try std.fmt.parseInt(u16, port_text, 10);

    {
        // sshd is ready once it says so; each `docker logs` is the bounded wait.
        const deadline = testNowMs() + 30_000;
        while (true) {
            var logs = try hostCommand(&.{ "docker", "logs", container }, 30_000);
            defer logs.deinit(testing.allocator);
            if (std.mem.indexOf(u8, logs.stderr, "Server listening") != null or
                std.mem.indexOf(u8, logs.stdout, "Server listening") != null) break;
            if (testNowMs() > deadline) return error.SshdNeverListened;
        }
    }

    // A private client config: the alias, port and identity come from it
    // (AC2: options from the config file are honoured), host keys go to a
    // private known_hosts with OpenSSH's default `ask` policy, and no agent.
    const config_text = try std.fmt.allocPrint(testing.allocator,
        \\Host conduit-test-host
        \\  HostName 127.0.0.1
        \\  Port {d}
        \\  User conduit
        \\  IdentityFile {s}
        \\  IdentitiesOnly yes
        \\  IdentityAgent none
        \\  UserKnownHostsFile {s}/known_hosts
        \\  GlobalKnownHostsFile /dev/null
        \\  StrictHostKeyChecking ask
        \\  UpdateHostKeys no
        \\
    , .{ port, key, work });
    defer testing.allocator.free(config_text);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "ssh_config", .data = config_text });
    const config_path = try std.fmt.allocPrint(testing.allocator, "{s}/ssh_config", .{work});
    defer testing.allocator.free(config_path);

    // A short private runtime directory, because the test's own temporary
    // directory is too deep for a unix socket path.
    const runtime_dir = try std.fmt.allocPrintSentinel(testing.allocator, "/tmp/conduit-ssh-test-{s}", .{tag}, 0);
    defer testing.allocator.free(runtime_dir);
    try testing.expect(sys.mkdir(runtime_dir, 0o700) != .failed);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime_dir) catch {}; // Best-effort cleanup of a private test directory.

    const path_entry = try std.fmt.allocPrint(testing.allocator, "PATH={s}", .{testing.environ.getPosix("PATH") orelse "/usr/bin:/bin"});
    defer testing.allocator.free(path_entry);
    var owner = try SshContext.create(testing.allocator, testing.io, .{
        .target = .{ .destination = "conduit-test-host", .config_file = config_path },
        .local_env = &.{ path_entry, "TERM=xterm-256color", "LANG=C.UTF-8" },
        .runtime_dir = runtime_dir,
    });
    defer owner.deinit();
    try testing.expectEqual(workspace.ExecutionContextKind.ssh, owner.kind());
    const context = SshContext.fromContext(&owner).?;
    const ref = owner.borrow();
    try testing.expectEqual(context, SshContext.fromRef(ref).?);
    try testing.expectEqual(State.disconnected, context.state());

    // Before connecting nothing may spawn or exec: a client with no master
    // would open a second, separately authenticated connection.
    try testing.expectError(error.Closed, ref.spawn(.{ .argv = &.{}, .env = &.{}, .cwd = "", .size = .{ .rows = 24, .cols = 80 } }));
    try testing.expectError(error.Unavailable, ref.run(testing.allocator, testing.io, .{ .argv = &.{"true"}, .cwd = "" }));

    // AC3 (context half): OpenSSH's host-key and passphrase prompts appear in
    // the master's terminal and are answered by typing into it.
    var master: TestTerminal = .{ .handle = context.masterTerminal() };
    defer master.deinit();
    try context.connect(.{ .rows = 24, .cols = 100 });
    try testing.expectEqual(State.connecting, context.state());
    try master.waitFor(0, "(yes/no", 20_000);
    try master.send("yes\r");
    try master.waitFor(0, "Enter passphrase", 20_000);
    try master.send(passphrase);
    try master.send("\r");
    try waitState(context, &master, .connected, 30_000);
    try testing.expect(std.mem.indexOf(u8, master.seen.items, passphrase) == null);
    try testing.expect(context.checkMaster());

    // AC1: two remote shells over the one master, each independent and
    // resizable, starting in a quoted cwd with the remote overlay only.
    const weird_dir = remote_project ++ "/it's $(x) `y`";
    const overlay = [_][]const u8{ "TERM_PROGRAM=conduit", "HOME=/local/home", "PATH=/local/bin", "CONDUIT_PROBE=a'b$c" };
    var a: TestTerminal = .{ .handle = try ref.spawn(.{ .argv = &.{}, .env = &overlay, .cwd = weird_dir, .size = .{ .rows = 24, .cols = 80 } }) };
    defer a.deinit();
    defer a.handle.destroy();
    var b: TestTerminal = .{ .handle = try ref.spawn(.{ .argv = &.{}, .env = &overlay, .cwd = remote_project, .size = .{ .rows = 30, .cols = 100 } }) };
    defer b.deinit();
    defer b.handle.destroy();

    const probe = "printf 'P%s tty=%s size=%s|\\n' \"$PWD|$TERM_PROGRAM|$HOME|$CONDUIT_PROBE|$PATH\" \"$(tty)\" \"$(stty size)\"\r";
    try a.send(probe);
    try a.waitFor(0, "P" ++ weird_dir ++ "|conduit|/home/conduit|a'b$c|", 20_000);
    try a.waitFor(0, "size=24 80|", 5_000);
    try b.send(probe);
    try b.waitFor(0, "P" ++ remote_project ++ "|conduit|/home/conduit|a'b$c|", 20_000);
    try b.waitFor(0, "size=30 100|", 5_000);
    // The local PATH never crossed.
    try testing.expect(std.mem.indexOf(u8, a.seen.items, "|/local/bin tty=") == null);
    // Distinct remote terminals.
    const a_tty = std.mem.indexOf(u8, a.seen.items, "tty=/dev/pts/").?;
    const b_tty = std.mem.indexOf(u8, b.seen.items, "tty=/dev/pts/").?;
    try testing.expect(!std.mem.eql(u8, a.seen.items[a_tty .. a_tty + 14], b.seen.items[b_tty .. b_tty + 14]));

    try a.send("export MARK=from-a; echo A_MARK=$MARK\r");
    try a.waitFor(0, "A_MARK=from-a", 5_000);
    const before_b = b.seen.items.len;
    try b.send("echo B_MARK=${MARK:-unset}\r");
    try b.waitFor(before_b, "B_MARK=unset", 5_000);
    const before_resize = b.seen.items.len;
    try b.handle.resize(.{ .rows = 50, .cols = 132 });
    try b.send("echo RESIZED=$(stty size | tr ' ' x)\r");
    try b.waitFor(before_resize, "RESIZED=50x132", 5_000);

    // Files and commands over exec channels on the same master.
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("conduit-ssh-file\n", try ref.readFile(testing.io, remote_project ++ "/notes.txt", &buffer));
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.TooLarge, ref.readFile(testing.io, remote_project ++ "/notes.txt", &tiny));
    var exact: [17]u8 = undefined;
    try testing.expectEqualStrings("conduit-ssh-file\n", try ref.readFile(testing.io, remote_project ++ "/notes.txt", &exact));
    try testing.expectError(error.NotFound, ref.readFile(testing.io, remote_project ++ "/absent", &buffer));
    try testing.expectError(error.IsADirectory, ref.readFile(testing.io, remote_project, &buffer));

    const Names = struct {
        list: std.ArrayList(u8) = .empty,
        dirs: usize = 0,
        fn visit(ptr: *anyopaque, entry: workspace.DirEntry) bool {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.list.appendSlice(testing.allocator, entry.name) catch return false;
            self.list.append(testing.allocator, '/') catch return false;
            if (entry.kind == .directory) self.dirs += 1;
            return true;
        }
    };
    var names: Names = .{};
    defer names.list.deinit(testing.allocator);
    try ref.listDir(testing.io, remote_project, .{ .context = &names, .visit_fn = Names.visit });
    for ([_][]const u8{ "alpha/", "beta/", "notes.txt/", "sub/", "it's $(x) `y`/" }) |name| {
        try testing.expect(std.mem.indexOf(u8, names.list.items, name) != null);
    }
    try testing.expectEqual(@as(usize, 2), names.dirs);
    try testing.expectError(error.NotFound, ref.listDir(testing.io, remote_project ++ "/absent", .{ .context = &names, .visit_fn = Names.visit }));
    try testing.expectError(error.NotADirectory, ref.listDir(testing.io, remote_project ++ "/notes.txt", .{ .context = &names, .visit_fn = Names.visit }));

    const stat = try ref.statPath(testing.io, remote_project ++ "/notes.txt");
    try testing.expectEqual(workspace.PathKind.file, stat.kind);
    try testing.expectEqual(@as(u64, 17), stat.size);
    try testing.expect(stat.mtime_ns > 0);
    try testing.expectEqual(workspace.PathKind.directory, (try ref.statPath(testing.io, weird_dir)).kind);
    try testing.expectError(error.NotFound, ref.statPath(testing.io, remote_project ++ "/absent"));

    var pwd = try ref.run(testing.allocator, testing.io, .{ .argv = &.{"pwd"}, .cwd = weird_dir });
    defer pwd.deinit(testing.allocator);
    try testing.expect(pwd.succeeded());
    try testing.expectEqualStrings(weird_dir ++ "\n", pwd.stdout);
    var piped = try ref.run(testing.allocator, testing.io, .{ .argv = &.{"cat"}, .cwd = "", .stdin = "through stdin" });
    defer piped.deinit(testing.allocator);
    try testing.expectEqualStrings("through stdin", piped.stdout);
    var failing = try ref.run(testing.allocator, testing.io, .{ .argv = &.{ "sh", "-c", "echo bad >&2; exit 3" }, .cwd = "" });
    defer failing.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 3), failing.exit_code);
    try testing.expectEqualStrings("bad\n", failing.stderr);
    // A remote 255 with the master alive is the command's own status.
    var own_255 = try ref.run(testing.allocator, testing.io, .{ .argv = &.{ "sh", "-c", "exit 255" }, .cwd = "" });
    defer own_255.deinit(testing.allocator);
    try testing.expectEqual(@as(?u8, 255), own_255.exit_code);
    try testing.expectError(error.CommandNotFound, ref.run(testing.allocator, testing.io, .{ .argv = &.{"conduit-no-such-program"}, .cwd = "" }));
    try testing.expectError(error.CommandNotFound, ref.run(testing.allocator, testing.io, .{ .argv = &.{"true"}, .cwd = "/no/such/dir" }));
    try testing.expectError(error.OutputTooLarge, ref.run(testing.allocator, testing.io, .{ .argv = &.{ "head", "-c", "100000", "/dev/zero" }, .cwd = "", .max_output = 1000 }));

    {
        var watch = try ref.watch(testing.allocator, testing.io, remote_project);
        defer watch.deinit();
        try testing.expect(!watch.pollChanges());
        var touched = try ref.run(testing.allocator, testing.io, .{ .argv = &.{ "touch", remote_project ++ "/created-by-test" }, .cwd = "" });
        touched.deinit(testing.allocator);
        // The remote loop fingerprints every `watch_interval_s`; poll the
        // non-blocking handle against a deadline.
        const deadline = testNowMs() + 20_000;
        while (!watch.pollChanges()) {
            if (testNowMs() > deadline) return error.WatchMissedChange;
            try testing.io.sleep(.fromMilliseconds(100), .awake);
        }
    }

    // AC1: every shell, exec channel, check and watch above rode one
    // authentication.
    try testing.expectEqual(@as(usize, 1), try acceptedAuthentications(container));

    // AC4: losing the connection (sshd's per-connection processes killed on
    // the server side) is detected, and the sessions end as disconnected.
    var killed = try hostCommand(&.{ "docker", "exec", container, "pkill", "-KILL", "-f", "sshd: conduit" }, 30_000);
    killed.deinit(testing.allocator);
    try waitState(context, &master, .lost, 30_000);
    const a_end = try a.waitExit(15_000);
    try testing.expectEqual(SessionEnd.disconnected, sessionEnd(a_end, false, context.checkMaster()));
    _ = try b.waitExit(15_000);
    try testing.expectError(error.Closed, ref.spawn(.{ .argv = &.{}, .env = &.{}, .cwd = "", .size = .{ .rows = 24, .cols = 80 } }));
    try testing.expectError(error.Unavailable, ref.readFile(testing.io, remote_project ++ "/notes.txt", &buffer));

    // Reconnect: a new master, a new passphrase prompt in the same terminal
    // view, and sessions spawn again.
    const before_reconnect = master.seen.items.len;
    try context.reconnect();
    try master.waitFor(before_reconnect, "Enter passphrase", 20_000);
    try master.send(passphrase);
    try master.send("\r");
    try waitState(context, &master, .connected, 30_000);
    try testing.expectEqual(@as(usize, 2), try acceptedAuthentications(container));
    {
        var c: TestTerminal = .{ .handle = try ref.spawn(.{ .argv = &.{ "sh", "-c", "echo AGAIN=$((40 + 2)); exec cat" }, .env = &.{}, .cwd = "", .size = .{ .rows = 24, .cols = 80 } }) };
        defer c.deinit();
        defer c.handle.destroy();
        try c.waitFor(0, "AGAIN=42", 20_000);

        // A deliberate hang-up is not a loss: the state lands on
        // `disconnected`, and the session's 255 is classified as an exit.
        context.disconnect();
        try testing.expectEqual(State.disconnected, context.state());
        const c_end = try c.waitExit(15_000);
        try testing.expectEqual(SessionEnd.exited, sessionEnd(c_end, true, false));
    }
    _ = try master.waitExit(15_000);
    try testing.expectEqual(State.disconnected, context.poll());
    try testing.expectError(error.Closed, ref.spawn(.{ .argv = &.{}, .env = &.{}, .cwd = "", .size = .{ .rows = 24, .cols = 80 } }));
    try testing.expectEqual(@as(usize, 2), try acceptedAuthentications(container));
}
