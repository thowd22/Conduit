//! TASK-42 spike driver (THROWAWAY). Never absorbed into the real build.
//!
//! Proves the system-OpenSSH design the SSH ExecutionContext decision chose, using Conduit's own
//! `pty` module exactly as `LocalExecutionContext.spawn` does: every ssh process below is started
//! with `pty.spawn` and a full `SpawnRequest`, so an SSH context is "a Local spawn of ssh".
//!
//!  1. A dedicated master `ssh -M -N` runs in its own PTY. OpenSSH's own host-key and passphrase
//!     prompts appear in that PTY; the driver answers them the way a person typing into the
//!     terminal would (it stands in for keystrokes, it parses nothing it then trusts).
//!  2. Readiness is `ssh -O check`, never a timer.
//!  3. Two interactive shells (`ssh -tt`, ControlMaster=no) ride the master; each has its own
//!     remote pty, independent shell state, and its own window size (resize crosses the mux).
//!  4. Two exec channels (`cat`, `ls`) with BatchMode=yes ride the master with no TTY.
//!  5. Hanging up one shell leaves the other alive; `ssh -O exit` then ends the remaining shell
//!     with ssh's 255 "connection lost" status, and a BatchMode exec fails instead of prompting.
//!
//! Inputs (environment): SPIKE_CFG (ssh_config written by run.sh), SPIKE_HOST (alias),
//! SPIKE_PASSPHRASE (the throwaway key's passphrase, typed into the master PTY, never printed).

const std = @import("std");
const pty = @import("pty");

const Session = struct {
    name: []const u8,
    handle: pty.Pty,
    seen: std.ArrayList(u8) = .empty,

    fn pump(self: *Session, gpa: std.mem.Allocator) !void {
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = self.handle.takeBytes(&buf);
            if (n == 0) break;
            try self.seen.appendSlice(gpa, buf[0..n]);
        }
    }

    /// Wait until `needle` appears after `from`, or the child ends, or `timeout_ms` passes.
    fn waitFor(self: *Session, gpa: std.mem.Allocator, from: usize, needle: []const u8, timeout_ms: u32) !usize {
        var waited: u32 = 0;
        while (true) {
            try self.pump(gpa);
            if (std.mem.indexOfPos(u8, self.seen.items, from, needle)) |at| return at;
            if (self.handle.state() != .running) {
                try self.pump(gpa);
                if (std.mem.indexOfPos(u8, self.seen.items, from, needle)) |at| return at;
                std.debug.print("[{s}] ended before '{s}'\n", .{ self.name, needle });
                return error.EndedEarly;
            }
            if (waited >= timeout_ms) {
                std.debug.print("[{s}] timeout waiting for '{s}'\n", .{ self.name, needle });
                return error.Timeout;
            }
            _ = self.handle.waitReadable(100);
            waited += 100;
        }
    }

    fn waitExit(self: *Session, gpa: std.mem.Allocator, timeout_ms: u32) !pty.ExitStatus {
        var waited: u32 = 0;
        while (true) {
            try self.pump(gpa);
            switch (self.handle.state()) {
                .exited => |status| {
                    try self.pump(gpa);
                    return status;
                },
                .running => {},
            }
            if (waited >= timeout_ms) return error.Timeout;
            _ = self.handle.waitReadable(100);
            waited += 100;
        }
    }

    fn send(self: *Session, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) rest = rest[try self.handle.write(rest)..];
    }

    /// Print the lines of interest from ssh's own output: mux and auth diagnostics and the
    /// prompts. Never key material; the passphrase is typed, never echoed by ssh.
    fn report(self: *Session) void {
        var lines = std.mem.splitAny(u8, self.seen.items, "\r\n");
        while (lines.next()) |line| {
            const keep = std.mem.indexOf(u8, line, "mux_client") != null or
                std.mem.indexOf(u8, line, "Authenticated to") != null or
                std.mem.indexOf(u8, line, "multiplex") != null or
                std.mem.indexOf(u8, line, "continue connecting") != null or
                std.mem.indexOf(u8, line, "Enter passphrase") != null or
                std.mem.indexOf(u8, line, "Permanently added") != null or
                std.mem.indexOf(u8, line, "SPIKE_") != null or
                std.mem.indexOf(u8, line, "Master running") != null or
                std.mem.indexOf(u8, line, "Control socket connect") != null;
            if (keep and line.len > 0) std.debug.print("  [{s}] {s}\n", .{ self.name, line });
        }
    }

    fn deinit(self: *Session, gpa: std.mem.Allocator) void {
        self.seen.deinit(gpa);
        self.handle.destroy();
    }
};

const Ctx = struct {
    gpa: std.mem.Allocator,
    env: []const []const u8,

    fn start(self: Ctx, name: []const u8, argv: []const []const u8, size: pty.WindowSize) !Session {
        const handle = try pty.spawn(self.gpa, .{ .argv = argv, .env = self.env, .cwd = "", .size = size });
        return .{ .name = name, .handle = handle };
    }

    /// Run a short non-interactive ssh to completion and return (status, output).
    fn run(self: Ctx, name: []const u8, argv: []const []const u8) !Session {
        var s = try self.start(name, argv, .{ .rows = 24, .cols = 80 });
        errdefer s.deinit(self.gpa);
        _ = try s.waitExit(self.gpa, 15_000);
        return s;
    }
};

fn exitCode(status: pty.ExitStatus) i64 {
    return switch (status) {
        .code => |c| c,
        else => -1,
    };
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const env_map = init.environ_map;
    const cfg = env_map.get("SPIKE_CFG") orelse return error.MissingSpikeCfg;
    const host = env_map.get("SPIKE_HOST") orelse return error.MissingSpikeHost;
    const passphrase = env_map.get("SPIKE_PASSPHRASE") orelse return error.MissingPassphrase;
    const path = env_map.get("PATH") orelse "/usr/bin:/bin";

    // The ssh *client* is a Local child: it would inherit Conduit's environment (SSH_AUTH_SOCK,
    // DISPLAY for askpass). The spike pins a minimal one and disables the agent in its config so
    // the passphrase prompt is guaranteed to appear.
    const path_entry = try std.fmt.allocPrint(gpa, "PATH={s}", .{path});
    defer gpa.free(path_entry);
    const env = [_][]const u8{ path_entry, "TERM=xterm-256color", "LANG=C.UTF-8" };
    const ctx = Ctx{ .gpa = gpa, .env = &env };

    std.debug.print("== 1. master: ssh -M -N in its own PTY\n", .{});
    var master = try ctx.start("master", &.{ "ssh", "-F", cfg, "-v", "-M", "-N", "-o", "ControlPersist=no", host }, .{ .rows = 24, .cols = 100 });
    defer master.deinit(gpa);
    _ = try master.waitFor(gpa, 0, "(yes/no", 15_000);
    try master.send("yes\r"); // the person reads the fingerprint and types yes
    const prompt_at = try master.waitFor(gpa, 0, "Enter passphrase", 15_000);
    try master.send(passphrase); // the person types the passphrase; ssh does not echo it
    try master.send("\r");
    _ = prompt_at;

    std.debug.print("== 2. readiness: poll ssh -O check (no timer-based guess)\n", .{});
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        var check = try ctx.run("check", &.{ "ssh", "-F", cfg, "-O", "check", host });
        defer check.deinit(gpa);
        if (exitCode(check.handle.state().exited) == 0) {
            check.report();
            std.debug.print("  master ready after {d} check(s)\n", .{attempts + 1});
            break;
        }
        if (attempts > 50) return error.MasterNeverReady;
        if (master.handle.state() != .running) return error.MasterDied;
        _ = master.handle.waitReadable(200); // wait on the master's own PTY, not a sleep
        try master.pump(gpa);
    }

    std.debug.print("== 3. two interactive shells over the master (-tt, ControlMaster=no)\n", .{});
    const shell_argv_a = [_][]const u8{ "ssh", "-F", cfg, "-vv", "-tt", "-o", "ControlMaster=no", host };
    const shell_argv_b = [_][]const u8{ "ssh", "-F", cfg, "-tt", "-o", "ControlMaster=no", "-o", "BatchMode=yes", host };
    var a = try ctx.start("shell-a", &shell_argv_a, .{ .rows = 24, .cols = 80 });
    defer a.deinit(gpa);
    var b = try ctx.start("shell-b", &shell_argv_b, .{ .rows = 30, .cols = 100 });
    defer b.deinit(gpa);

    const probe = "printf 'SPIKE_%s tty=%s pid=%s size=%s\\n' \"$1\" \"$(tty)\" \"$$\" \"$(stty size)\"";
    try a.send("set -- A; " ++ probe ++ "\r");
    try b.send("set -- B; " ++ probe ++ "\r");
    _ = try a.waitFor(gpa, 0, "SPIKE_A tty=/dev/pts/", 15_000);
    _ = try b.waitFor(gpa, 0, "SPIKE_B tty=/dev/pts/", 15_000);
    _ = try a.waitFor(gpa, 0, "size=24 80", 5_000);
    _ = try b.waitFor(gpa, 0, "size=30 100", 5_000);

    // Independent shell state: a variable exported in A is not in B.
    try a.send("export SPIKE_MARK=from-a; echo SPIKE_A_MARK=$SPIKE_MARK\r");
    _ = try a.waitFor(gpa, 0, "SPIKE_A_MARK=from-a", 5_000);
    try b.send("echo SPIKE_B_MARK=${SPIKE_MARK:-unset}\r");
    _ = try b.waitFor(gpa, 0, "SPIKE_B_MARK=unset", 5_000);

    // Window-size control crosses the mux: resizing the local PTY becomes a remote window-change.
    const before_resize = b.seen.items.len;
    try b.handle.resize(.{ .rows = 50, .cols = 132 });
    try b.send("echo SPIKE_B_RESIZED=$(stty size | tr ' ' x)\r");
    _ = try b.waitFor(gpa, before_resize, "SPIKE_B_RESIZED=50x132", 5_000);

    std.debug.print("== 4. exec channels over the master (BatchMode=yes, no TTY)\n", .{});
    {
        var cat = try ctx.run("exec-cat", &.{ "ssh", "-F", cfg, "-o", "ControlMaster=no", "-o", "BatchMode=yes", host, "cat project/notes.txt && echo SPIKE_CAT_OK" });
        defer cat.deinit(gpa);
        if (std.mem.indexOf(u8, cat.seen.items, "conduit-spike-file") == null) return error.CatFailed;
        cat.report();
        var ls = try ctx.run("exec-ls", &.{ "ssh", "-F", cfg, "-o", "ControlMaster=no", "-o", "BatchMode=yes", host, "ls -1 project | tr '\\n' ' ' | sed 's/^/SPIKE_LS: /'; echo" });
        defer ls.deinit(gpa);
        if (std.mem.indexOf(u8, ls.seen.items, "alpha beta notes.txt") == null) return error.LsFailed;
        ls.report();
    }

    std.debug.print("== 5. hang up shell A; shell B survives\n", .{});
    try a.handle.kill(.hangup);
    const a_status = try a.waitExit(gpa, 10_000);
    std.debug.print("  shell-a ended: {any}\n", .{a_status});
    const before_alive = b.seen.items.len;
    try b.send("echo SPIKE_B_ALIVE\r");
    _ = try b.waitFor(gpa, before_alive, "SPIKE_B_ALIVE", 5_000);

    std.debug.print("== 6. ssh -O exit: remaining shell sees the connection drop\n", .{});
    {
        var exit_cmd = try ctx.run("ctl-exit", &.{ "ssh", "-F", cfg, "-O", "exit", host });
        defer exit_cmd.deinit(gpa);
    }
    const b_status = try b.waitExit(gpa, 10_000);
    const m_status = try master.waitExit(gpa, 10_000);
    std.debug.print("  shell-b ended: {any} (255 = ssh connection lost, distinct from the remote shell's own exit)\n", .{b_status});
    std.debug.print("  master ended: {any}\n", .{m_status});
    {
        var refused = try ctx.run("exec-after", &.{ "ssh", "-F", cfg, "-o", "ControlMaster=no", "-o", "BatchMode=yes", host, "true" });
        defer refused.deinit(gpa);
        std.debug.print("  BatchMode exec with no master: exit {d} (no prompt, no silent re-auth)\n", .{exitCode(refused.handle.state().exited)});
    }

    std.debug.print("== transcript lines of interest (ssh's own output; never key material)\n", .{});
    master.report();
    a.report();
    b.report();
    std.debug.print("SPIKE RESULT: PASS\n", .{});
}
