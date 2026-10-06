//! Conduit's executable entry point, and the root of the `app` module.
//!
//! `app` is the composition root: it is the one module allowed to see every
//! other module, and it owns process lifetime. Everything else hangs off the
//! downward dependency edges declared in `build.zig`.
//!
//! It opens a real window with a real OpenGL context, draws into the framebuffer
//! the renderer always draws into, and runs until the window closes — rendering
//! only when something changed. `--hidden` gives doc-2's headless contract: the
//! same window and the same GL context, never shown, with the pixels read back
//! from the surface instead of the screen.
//!
//! # The window and the loop (TASK-7)
//!
//! - **Window and events** belong to `platform`: a window, its GL context, and the
//!   translation of SDL's events into Conduit's own. `app` never names an OS type.
//! - **The surface** belongs to `render`: one RGBA8 framebuffer that every draw goes
//!   into, a blit to the screen for a visible window, and a `glReadPixels` readback
//!   for a hidden one.
//! - **"What to do next"** belongs to `app`, on the main thread (architecture §5):
//!   the `Scheduler` below is the whole of it — draw when dirty, otherwise do
//!   nothing at all.
//! - **Render on demand.** A frame is drawn for the first one, for a resize, for a
//!   display-scale change and for an expose, and at no other time. `--force-redraw`
//!   draws every iteration instead, which exists to measure this against.
//! - **The main thread is the render thread.** The wait between events is a blocking
//!   wait inside SDL, so an untouched window costs no CPU.
//!
//! # The terminal (TASK-11)
//!
//! - **`session` owns one terminal and its optional PTY; `render` draws it.**
//!   The app wires that session to the window: it requests a shell spawn, moves
//!   bytes between the child and terminal, and asks the grid renderer for a
//!   frame whenever something says the screen is out of date.
//! - **Both directions of the child are non-blocking.** `Pty.takeBytes` copies
//!   out of the read thread's queue and `Terminal.takeResponses` drains the
//!   terminal's answers; neither waits, so the loop's blocking wait inside SDL
//!   is still the only wait a frame has.
//! - **Startup IO is not the loop's IO.** Scanning every font on the machine
//!   and forking a child are both done on a worker thread and handed over
//!   whole; the thread that draws never waits on a filesystem or on a child.
//!   A display-scale change re-loads the face the same way, polled rather than
//!   joined, so the frame that notices it is not the frame that waits for it.
//! - **Colours cross as values.** `theme.Color` becomes `render.Rgba` in the
//!   app, which is the only module allowed to see both, and the grid renderer
//!   receives colours and never a palette.
//!
//! # Diagnostics (TASK-6)
//!
//! The diagnostics infrastructure lives here because `app` is the module that
//! starts logging before any other module exists, and the only one that sees
//! the command line and the environment. It is not a sixteenth module: the
//! module list is fixed by `docs/architecture.md` §2.
//!
//! - **Levels** are `std.log.Level`, ordered `err` < `warn` < `info` < `debug`.
//!   The compiled-in level is always `debug` (see `std_options`) and the
//!   *effective* level is a runtime value, because the point of the task is
//!   that a test driver or a CI job can turn it up without a rebuild.
//! - **Output** goes to stderr *and* to one log file per run.
//! - **Level** comes from `--log-level=<level>`, or `CONDUIT_LOG_LEVEL`.
//! - **File** comes from `--log-file=<path>` / `CONDUIT_LOG_FILE` for an exact
//!   path, or `--log-dir=<dir>` / `CONDUIT_LOG_DIR` for the directory a
//!   per-run name is generated in. With neither, the file lands under the
//!   system temporary directory.
//! - **Precedence** is flag, then environment, then the built-in default. A
//!   flag always wins over the environment variable.
//! - **Discovery** is `--print-log-path`: it prints the log path on stdout and
//!   exits 0 without opening a window, so it works headless.
//! - **Panics** are captured by `panic` below into a crash report beside the
//!   log file, holding the stack trace and the tail of the log.
//! - **Sensitive content** — terminal contents, clipboard data, credentials and
//!   agent prompts (CONDUIT.md §11, AGENTS.md) — may only be logged through
//!   `sensitiveLog`, which is pinned to `debug` and cannot be promoted by any
//!   level setting.

const std = @import("std");
const platform = @import("platform");
const render = @import("render");
const font = @import("font");
const term = @import("term");
const pty = @import("pty");
const session = @import("session");
const workspace = @import("workspace");
const theme = @import("theme");
const ui = @import("ui");
const link = @import("link");
const palette_mod = @import("palette");
const config = @import("config");
const testdriver = @import("testdriver");
/// The input module, imported under a name that does not collide with the app's
/// `input` buffer field. A module shadowed by a local reads as "the buffer"
/// when it means "the module", which is the kind of ambiguity that costs an
/// hour.
const inputmod = @import("input");

const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const File = std.Io.File;
const Io = std.Io;
const Writer = std.Io.Writer;

/// Overrides the standard library's logging entry point.
///
/// `log_level` is `debug` unconditionally and the real filtering happens at run
/// time in `appLog`. The cost is that `debug` format strings are compiled into
/// release builds; the benefit, which is the requirement, is that
/// `--log-level=debug` and `CONDUIT_LOG_LEVEL=debug` work on the binary a user
/// already has.
pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = appLog,
};

/// Replaces the default panic handler with one that writes a crash report
/// first. See `writeCrashReport` for the report's contents and location.
pub const panic = std.debug.FullPanic(onPanic);

/// The log scope for process-level events. Every line the app logs goes
/// through a scope, never straight to a stream.
pub const log = std.log.scoped(.app);

/// The product name Conduit lends to the platform before its video subsystem starts.
pub const app_name: [:0]const u8 = "Conduit";
/// The stable reverse-domain identity shared with Conduit's Linux desktop payload.
pub const app_identifier: [:0]const u8 = "io.github.thowd22.Conduit";

/// The version Conduit reports at startup and for `--version`. Stamped by
/// `zig build -Dversion=<semver>` through the generated `build_options`
/// module; a build without the flag reports `0.0.0-dev`.
pub const version: [:0]const u8 = @import("build_options").version;

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// A log level, ordered `err` < `warn` < `info` < `debug`. That is the order
/// `std.log.Level` declares, and therefore the order the filter uses.
pub const Level = std.log.Level;

/// The level used when neither the flag nor the environment variable is given:
/// the standard library's own default, `debug` in a debug build and `info` in
/// a release one.
pub const default_level: Level = std.log.default_level;

/// Environment fallback for `--log-level`.
pub const level_env = "CONDUIT_LOG_LEVEL";
/// Environment fallback for `--log-file`.
pub const file_env = "CONDUIT_LOG_FILE";
/// Environment fallback for `--log-dir`.
pub const dir_env = "CONDUIT_LOG_DIR";

/// The environment variables that stand in for a command line, in the order
/// they are consulted. `dir_vars` are the platform's own temporary-directory
/// variables, tried after `dir_env`.
pub const temp_dir_vars = [_][]const u8{ "TMPDIR", "TEMP", "TMP" };

/// The directory the log file falls back to when no temporary directory is
/// named by the environment. It is inside the build cache so a run never
/// writes into the user's working tree.
pub const fallback_log_dir = ".zig-cache/conduit";

/// The longest path Conduit stores: comfortably above `MAX_PATH` on Windows
/// and above any plausible temporary directory on POSIX.
pub const path_capacity = 1024;

/// A read-only view of the environment, so that `parseArgs` stays pure and
/// testable without a real process environment.
pub const EnvSource = struct {
    ctx: *const anyopaque,
    getFn: *const fn (ctx: *const anyopaque, key: []const u8) ?[]const u8,

    /// The value of `key`, or `null` when it is unset or empty. An empty
    /// variable counts as unset: `FOO=` is how a shell says "nothing", not
    /// "the empty path".
    pub fn get(self: EnvSource, key: []const u8) ?[]const u8 {
        const value = self.getFn(self.ctx, key) orelse return null;
        return if (value.len == 0) null else value;
    }
};

/// Everything the command line and the environment can say about diagnostics,
/// resolved and ready for the filesystem to act on.
pub const Options = struct {
    /// The effective minimum level.
    level: Level = default_level,
    /// An exact log file path, from `--log-file` or `CONDUIT_LOG_FILE`. When
    /// set, the file is truncated if it already exists: the caller named that
    /// path, so the caller owns its uniqueness. When `null`, a unique per-run
    /// path is generated inside `dir`.
    file: ?[]const u8 = null,
    /// The directory a generated per-run log file is created in. Never null:
    /// `parseArgs` resolves it from the flags, then the environment, then the
    /// platform temporary directory, then `fallback_log_dir`.
    dir: []const u8 = fallback_log_dir,
    /// Print the resolved log path on stdout and exit, without running the app.
    print_log_path: bool = false,
    /// Print usage on stdout and exit.
    help: bool = false,
    /// Print `conduit <version>` on stdout and exit.
    print_version: bool = false,
    /// The window to open and how long to run, from the window flags.
    run: Run = .{},
};

/// The window the run opens and how long it runs for.
///
/// These settings decide what the app *does*, where the ones above decide what it
/// *says* about what it does. Both come from the same command line in one pass: a
/// person typing `--hidden --width=640` means both, and two passes over one
/// command line would mean two places that have to know about each other's flags.
///
/// There are no environment fallbacks for these, on purpose: doc-2 fixes the
/// window size and scale by flag at startup, so that a screenshot in CI is the
/// same image on every machine.
pub const Run = struct {
    /// The window's width in logical pixels.
    width: u32 = default_width,
    /// The window's height in logical pixels.
    height: u32 = default_height,
    /// Fix physical pixels per logical pixel instead of following the display.
    /// Null preserves the native display scale.
    scale: ?f32 = null,
    /// Create the window hidden and never show it. The window and its GL context
    /// are real all the same (doc-2): headless is a peer of the on-screen path.
    hidden: bool = false,
    /// Draw a frame every iteration of the loop whether or not anything changed.
    ///
    /// A measurement mode, not a feature: it is what the idle cost of
    /// render-on-demand is measured against, and `--self-test` reports the frame
    /// count either way.
    force_redraw: bool = false,
    /// Leave after this many milliseconds. `null` runs until the window closes.
    run_ms: ?u32 = null,
    /// Run the TASK-7 integration check — a real window, real events, real
    /// pixels — and print what it measured.
    self_test: bool = false,
    /// Print numbered lines, scroll back with a real wheel event, read the
    /// surface back and print what the viewport showed — then exit.
    scroll_test: bool = false,
    /// Drive a real press and drag through SDL's queue, `App.handle`, `input`
    /// and the terminal, with Shift held and not held, then read the surface
    /// back — print what it measured, then exit.
    mouse_test: bool = false,
    /// Prove copy, paste, bracketed paste, middle-click primary paste, the
    /// Ctrl+C rule and the OSC 52 policies through SDL's queue and a real
    /// child, on SDL's offscreen driver so only process-local clipboards are
    /// touched — print what it measured, then exit.
    clipboard_test: bool = false,
    /// Draw and mutate all four UI primitives over a real terminal surface,
    /// measure their pixels and idle work, then exit.
    ui_test: bool = false,
    /// Drive a real SDL text-editing/commit sequence over a real PTY, measure
    /// the inline preedit and exact committed bytes, then exit.
    ime_test: bool = false,
    /// Exercise the production workspace/sidebar tree, inset geometry and
    /// mouse/keyboard switching paths, capture them, then exit.
    sidebar_test: bool = false,
    /// Exercise production tab creation, rename, switching, reordering,
    /// attention and close confirmation through real SDL events, then exit.
    tabs_test: bool = false,
    /// Exercise nested pane layout, focus, resize, zoom and close through real
    /// PTYs and SDL events, then exit.
    panes_test: bool = false,
    /// Exercise the persistent scratchpad's startup, presentations, input
    /// isolation and restart lifecycle through real PTYs and SDL events.
    scratchpad_test: bool = false,
    /// Exercise the production command palette through real SDL keyboard and
    /// mouse events, including fuzzy search and nested arguments.
    palette_test: bool = false,
    /// Exercise multiple independent workspace terminals, pane layouts and
    /// scratchpads through production palette/sidebar actions and real PTYs.
    workspaces_test: bool = false,
    /// Exercise terminal URL semantics, modifier hover and opening through
    /// real SDL pointer events while recording the requested URL in process.
    links_test: bool = false,
    /// Exercise full-scrollback search through production actions, semantic
    /// Input, SDL events and the shared renderer.
    search_test: bool = false,
    /// Exercise the terminal context menu: right-click placement and rows,
    /// keyboard navigation, the paste alternative and DEC mouse reporting
    /// through real PTYs and SDL events, then exit.
    menu_test: bool = false,
    /// The session layer of the `mouse.right_click` setting, from
    /// `--right-click=`. Null leaves the built-in default standing.
    right_click: ?config.RightClick = null,
    /// Explicit local endpoint for the in-app JSON-RPC automation server.
    /// Null means no listener exists in any build mode.
    test_driver_endpoint: ?[]const u8 = null,
    /// The run-scoped directory where driver screenshots are created. When the
    /// driver is enabled and this is null, `runApp` generates a unique one.
    test_artifact_dir: ?[]const u8 = null,
    /// Exercise the automation endpoint end to end and exit with its result.
    driver_test: bool = false,
    /// Run this line through the shell and leave when it does, instead of
    /// opening an interactive one.
    ///
    /// How a headless run reaches a *known* screen: a person types, this does
    /// not need a keyboard, and the app ends by itself when the line is done
    /// rather than waiting for a window that will never be closed.
    command: ?[]const u8 = null,
    /// Write the last frame the app drew to this path as an RGBA PNG.
    screenshot: ?[]const u8 = null,
    /// The family to draw the grid with. Empty is the bundled face, and a
    /// family that is not installed falls back to it with a log line.
    font_family: []const u8 = "",
    /// Run the grid renderer's own check — a screen whose every cell is known,
    /// read back pixel by pixel at two display scales, with the work each frame
    /// did counted — and exit.
    grid_test: bool = false,
    /// Run with no child behind the terminal.
    ///
    /// A check needs a grid that is not moving under it. `--self-test` turns
    /// this on unless a `--command` says otherwise, because a shell's output
    /// arriving mid-measurement would make the measurement about the shell.
    no_child: bool = false,
    /// Start the shell exactly as it would start without Conduit: no `--posix`,
    /// no `ENV`, no `ZDOTDIR` swap, and therefore no working-directory or prompt
    /// reports from Conduit's scripts. v0.1 has no config file, so this flag is
    /// how shell integration is turned off.
    no_shell_integration: bool = false,
};

/// The palette a run draws with. Slot order is `theme.Role`'s, which is the
/// ANSI order a terminal's colours are specified in: the eight normal colours,
/// then the eight bright ones, then the four roles that are not one of the 16.
///
/// TASK-38 replaces this with the theme engine and a file format. Until then a
/// run has exactly one palette, and saying so here is better than having the
/// renderer invent one.
pub const default_palette: theme.Palette = .{
    .colors = .{
        .{ .r = 0x1a, .g = 0x1c, .b = 0x24 }, // black
        .{ .r = 0xcc, .g = 0x55, .b = 0x55 }, // red
        .{ .r = 0x7f, .g = 0xb8, .b = 0x74 }, // green
        .{ .r = 0xd6, .g = 0xb0, .b = 0x55 }, // yellow
        .{ .r = 0x61, .g = 0x7f, .b = 0xd4 }, // blue
        .{ .r = 0xb4, .g = 0x7a, .b = 0xd0 }, // magenta
        .{ .r = 0x56, .g = 0xb6, .b = 0xc2 }, // cyan
        .{ .r = 0xc8, .g = 0xc8, .b = 0xd2 }, // white
        .{ .r = 0x4a, .g = 0x4f, .b = 0x5c }, // bright_black
        .{ .r = 0xe0, .g = 0x6c, .b = 0x6c }, // bright_red
        .{ .r = 0x9a, .g = 0xd0, .b = 0x8c }, // bright_green
        .{ .r = 0xec, .g = 0xc8, .b = 0x6a }, // bright_yellow
        .{ .r = 0x7c, .g = 0x9c, .b = 0xe8 }, // bright_blue
        .{ .r = 0xd0, .g = 0x92, .b = 0xe4 }, // bright_magenta
        .{ .r = 0x6c, .g = 0xcc, .b = 0xd6 }, // bright_cyan
        .{ .r = 0xf0, .g = 0xf0, .b = 0xf6 }, // bright_white
        .{ .r = 0x16, .g = 0x1a, .b = 0x22 }, // background
        .{ .r = 0xd8, .g = 0xd8, .b = 0xe0 }, // foreground
        .{ .r = 0x2c, .g = 0x3a, .b = 0x4d }, // selection
        .{ .r = 0x7c, .g = 0x9c, .b = 0xe8 }, // accent
    },
};

/// A palette colour as a surface colour.
///
/// This function is the whole bridge between the two types. `theme.Color` and
/// `render.Rgba` are deliberately different types and neither module may
/// import the other, so the conversion happens here, in the one module that is
/// allowed to see both, and everything downstream works with `Rgba`.
pub fn surfaceColor(color: theme.Color) render.Rgba {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

/// `palette` as the colours the grid renderer draws with.
///
/// Only the sixteen ANSI roles are named: the grid resolves the rest of the
/// terminal's 256 slots arithmetically, because those are the same in every
/// terminal and are not a theme's to change.
pub fn gridColors(palette: theme.Palette) render.Colors {
    var ansi: [render.ansi_count]render.Rgba = undefined;
    for (std.enums.values(theme.Role), 0..) |role, slot| {
        if (role.isAnsi()) ansi[slot] = surfaceColor(palette.get(role));
    }
    return .{
        .ansi = ansi,
        .foreground = surfaceColor(palette.get(.foreground)),
        .background = surfaceColor(palette.get(.background)),
        .cursor = surfaceColor(palette.get(.foreground)),
        .selection = surfaceColor(palette.get(.selection)),
    };
}

/// The window size a run opens with when the command line does not say.
pub const default_width: u32 = 960;
pub const default_height: u32 = 640;

/// The renderer checks own their viewport and font so captures are comparable
/// between runs rather than inheriting whichever diagnostic flags happened to
/// be on the command line.
const ui_test_width: u32 = 640;
const ui_test_height: u32 = 360;

fn optionsForRun(options: Options) Options {
    if (!options.run.ui_test and !options.run.ime_test and !options.run.driver_test and
        !options.run.sidebar_test and !options.run.tabs_test and !options.run.panes_test and
        !options.run.scratchpad_test and !options.run.palette_test and
        !options.run.workspaces_test and !options.run.links_test and
        !options.run.search_test and !options.run.menu_test) return options;
    var resolved = options;
    resolved.run.width = ui_test_width;
    resolved.run.height = ui_test_height;
    resolved.run.scale = 1.0;
    resolved.run.hidden = true;
    resolved.run.force_redraw = false;
    resolved.run.run_ms = null;
    resolved.run.command = null;
    resolved.run.font_family = "";
    resolved.run.no_child = options.run.ui_test or options.run.driver_test or options.run.sidebar_test or
        options.run.scratchpad_test;
    return resolved;
}

/// A rejected command line or environment value. None of these are panics:
/// malformed external input must never crash the app (CONDUIT.md §11).
pub const ConfigError = error{
    UnknownFlag,
    MissingValue,
    InvalidLogLevel,
    InvalidSize,
    InvalidScale,
    InvalidRightClick,
};

/// A window dimension: at least one pixel, because a window of no pixels is not a
/// window, and there is no honest reading of `--width=0`.
fn parseDimension(text: []const u8) ConfigError!u32 {
    const value = std.fmt.parseInt(u32, text, 10) catch return error.InvalidSize;
    if (value < 1) return error.InvalidSize;
    return value;
}

/// A deterministic screenshot scale. Display scale follows the platform only
/// when the flag is absent; malformed or vanishing factors are rejected.
fn parseScale(text: []const u8) ConfigError!f32 {
    const value = std.fmt.parseFloat(f32, text) catch return error.InvalidScale;
    if (!std.math.isFinite(value) or value < platform.Scale.min_factor) return error.InvalidScale;
    return value;
}

/// A millisecond count, where zero is a real answer: a run budget of zero leaves as
/// soon as the first frame is on the surface.
fn parseMilliseconds(text: []const u8) ConfigError!u32 {
    return std.fmt.parseInt(u32, text, 10) catch error.InvalidSize;
}

/// Parse a level name, case-insensitively.
///
/// Both spellings are accepted: the enum tag (`err`, `warn`, `info`, `debug`)
/// and the word `std.log.Level` prints (`error`, `warning`, `info`, `debug`),
/// because both are what people type.
pub fn parseLevel(text: []const u8) ConfigError!Level {
    inline for (comptime std.enums.values(Level)) |level| {
        if (std.ascii.eqlIgnoreCase(text, @tagName(level))) return level;
        if (std.ascii.eqlIgnoreCase(text, level.asText())) return level;
    }
    return error.InvalidLogLevel;
}

/// Resolve the diagnostics options from a command line and an environment.
///
/// `args` includes `argv[0]`, exactly as the operating system hands it over.
///
/// Precedence is flag, then environment, then the built-in default. The flag
/// wins even when the environment variable is also set, so a person at a
/// terminal is never overruled by a stale export. Every value is taken from the
/// flag if the flag is present, otherwise from the environment, and the
/// environment is consulted at most once per setting.
pub fn parseArgs(args: []const []const u8, env: EnvSource) ConfigError!Options {
    var flag_level: ?[]const u8 = null;
    var flag_file: ?[]const u8 = null;
    var flag_dir: ?[]const u8 = null;
    var print_log_path = false;
    var help = false;
    var print_version = false;
    var run: Run = .{};

    var i: usize = if (args.len == 0) 0 else 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
            break;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            print_version = true;
            break;
        } else if (std.mem.eql(u8, arg, "--print-log-path")) {
            print_log_path = true;
        } else if (namesValue(arg, "--log-level")) {
            flag_level = try takeValue(arg, "--log-level", args, &i);
        } else if (namesValue(arg, "--log-file")) {
            flag_file = try takeValue(arg, "--log-file", args, &i);
        } else if (namesValue(arg, "--log-dir")) {
            flag_dir = try takeValue(arg, "--log-dir", args, &i);
        } else if (namesValue(arg, "--width")) {
            run.width = try parseDimension(try takeValue(arg, "--width", args, &i));
        } else if (namesValue(arg, "--height")) {
            run.height = try parseDimension(try takeValue(arg, "--height", args, &i));
        } else if (namesValue(arg, "--scale")) {
            run.scale = try parseScale(try takeValue(arg, "--scale", args, &i));
        } else if (namesValue(arg, "--run-ms")) {
            run.run_ms = try parseMilliseconds(try takeValue(arg, "--run-ms", args, &i));
        } else if (std.mem.eql(u8, arg, "--hidden")) {
            run.hidden = true;
        } else if (std.mem.eql(u8, arg, "--force-redraw")) {
            run.force_redraw = true;
        } else if (std.mem.eql(u8, arg, "--self-test")) {
            run.self_test = true;
        } else if (std.mem.eql(u8, arg, "--scroll-test")) {
            run.scroll_test = true;
        } else if (std.mem.eql(u8, arg, "--mouse-test")) {
            run.mouse_test = true;
        } else if (std.mem.eql(u8, arg, "--clipboard-test")) {
            run.clipboard_test = true;
        } else if (std.mem.eql(u8, arg, "--ui-test")) {
            run.ui_test = true;
        } else if (std.mem.eql(u8, arg, "--ime-test")) {
            run.ime_test = true;
        } else if (std.mem.eql(u8, arg, "--sidebar-test")) {
            run.sidebar_test = true;
        } else if (std.mem.eql(u8, arg, "--tabs-test")) {
            run.tabs_test = true;
        } else if (std.mem.eql(u8, arg, "--panes-test")) {
            run.panes_test = true;
        } else if (std.mem.eql(u8, arg, "--scratchpad-test")) {
            run.scratchpad_test = true;
        } else if (std.mem.eql(u8, arg, "--palette-test")) {
            run.palette_test = true;
        } else if (std.mem.eql(u8, arg, "--workspaces-test")) {
            run.workspaces_test = true;
        } else if (std.mem.eql(u8, arg, "--links-test")) {
            run.links_test = true;
        } else if (std.mem.eql(u8, arg, "--search-test")) {
            run.search_test = true;
        } else if (std.mem.eql(u8, arg, "--menu-test")) {
            run.menu_test = true;
        } else if (namesValue(arg, "--right-click")) {
            run.right_click = config.RightClick.parse(try takeValue(arg, "--right-click", args, &i)) catch
                return error.InvalidRightClick;
        } else if (namesValue(arg, "--test-driver")) {
            run.test_driver_endpoint = try takeValue(arg, "--test-driver", args, &i);
        } else if (namesValue(arg, "--test-artifact-dir")) {
            run.test_artifact_dir = try takeValue(arg, "--test-artifact-dir", args, &i);
        } else if (std.mem.eql(u8, arg, "--driver-test")) {
            run.driver_test = true;
        } else if (namesValue(arg, "--command")) {
            run.command = try takeValue(arg, "--command", args, &i);
        } else if (namesValue(arg, "--screenshot")) {
            run.screenshot = try takeValue(arg, "--screenshot", args, &i);
        } else if (namesValue(arg, "--font")) {
            run.font_family = try takeValue(arg, "--font", args, &i);
        } else if (std.mem.eql(u8, arg, "--grid-test")) {
            run.grid_test = true;
        } else if (std.mem.eql(u8, arg, "--no-child")) {
            run.no_child = true;
        } else if (std.mem.eql(u8, arg, "--no-shell-integration")) {
            run.no_shell_integration = true;
        } else {
            return error.UnknownFlag;
        }
    }

    // The environment is only read for a setting the flag did not already
    // decide, which is what makes "flag beats environment" true by
    // construction rather than by an ordering argument.
    const level_text = flag_level orelse env.get(level_env);
    const dir = flag_dir orelse env.get(dir_env) orelse firstEnv(env, temp_dir_vars[0..]) orelse fallback_log_dir;

    return .{
        .level = if (level_text) |text| try parseLevel(text) else default_level,
        .file = flag_file orelse env.get(file_env),
        .dir = dir,
        .print_log_path = print_log_path,
        .help = help,
        .print_version = print_version,
        .run = run,
    };
}

/// The value of the first of `keys` that the environment sets.
fn firstEnv(env: EnvSource, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (env.get(key)) |value| return value;
    }
    return null;
}

/// Whether `arg` names `name` as a value-taking flag, in either the
/// `--name=value` or the bare `--name` spelling. The value itself is read by
/// `takeValue`; this only decides which branch of the walk a flag belongs to.
fn namesValue(arg: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, arg, name)) return true;
    return std.mem.startsWith(u8, arg, name) and arg.len > name.len and arg[name.len] == '=';
}

/// Read the value of a flag that `namesValue` matched, and leave `i` pointing at
/// the next unread argument in both spellings.
///
/// A missing or empty value is `error.MissingValue` rather than a silent
/// fallback: `--log-level` with nothing after it is a mistake in the command
/// line, and quietly logging at a different level than the one that was typed
/// is the worst possible answer to that mistake.
fn takeValue(arg: []const u8, name: []const u8, args: []const []const u8, i: *usize) ConfigError![]const u8 {
    if (std.mem.eql(u8, arg, name)) {
        if (i.* + 1 >= args.len) return error.MissingValue;
        const value = args[i.* + 1];
        // A value that looks like the next flag is a missing value, not a value.
        if (value.len == 0 or std.mem.startsWith(u8, value, "-")) return error.MissingValue;
        i.* += 1;
        return value;
    }
    const value = arg[name.len + 1 ..];
    // A value that looks like a flag is a missing value in this spelling too:
    // `--log-level=--dir` is a mistyped command line, not a level named
    // "--dir".
    if (value.len == 0 or std.mem.startsWith(u8, value, "-")) return error.MissingValue;
    return value;
}

// ---------------------------------------------------------------------------
// Per-run paths
// ---------------------------------------------------------------------------

/// A per-run identifier: `run-20261004T213800Z-112233`.
///
/// The timestamp makes a run readable at a glance; the random bytes are what
/// make it unique. Uniqueness is not merely probable: the generated file is
/// opened with `exclusive = true`, so a collision is a detectable error and
/// never a silent overwrite.
pub fn runIdPattern(buf: []u8, stamp: []const u8, random: [3]u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "run-{s}-{x:0>2}{x:0>2}{x:0>2}", .{
        stamp,
        random[0],
        random[1],
        random[2],
    });
}

/// Seconds since the epoch at 9999-12-31T23:59:59Z. A clock beyond that is
/// not a plausible date, and clamping it keeps the year loop bounded.
const max_stamp_seconds: i96 = 253_402_300_799;

/// The UTC stamp inside a run id: `YYYYMMDDTHHMMSSZ`.
///
/// The input is clamped rather than trusted: the clock is external input, and
/// a nonsensical value must produce a stamp, not a five-hundred-billion-iteration
/// loop in `calculateYearDay`.
pub fn stampPattern(buf: []u8, epoch_seconds: i96) std.fmt.BufPrintError![]const u8 {
    const clamped = std.math.clamp(epoch_seconds, 0, max_stamp_seconds);
    const seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(clamped) };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    const year: u16 = year_day.year;
    const month: u8 = @intCast(@intFromEnum(month_day.month));
    const day: u32 = @intCast(month_day.day_index + 1);
    const hours: u32 = day_seconds.getHoursIntoDay();
    const minutes: u32 = day_seconds.getMinutesIntoHour();
    const seconds_of_minute: u32 = day_seconds.getSecondsIntoMinute();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds_of_minute,
    });
}

/// Join `dir` and `name` with the platform separator.
pub fn joinPath(buf: []u8, dir: []const u8, name: []const u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, name });
}

/// The crash report path belonging to a log file: the log's name with its
/// `.log` suffix replaced by `.crash.txt`, so a report is always found beside
/// the log it explains and never mistaken for a log itself.
pub fn crashPathFor(buf: []u8, log_path: []const u8) std.fmt.BufPrintError![]const u8 {
    const stem = if (std.mem.endsWith(u8, log_path, ".log"))
        log_path[0 .. log_path.len - ".log".len]
    else
        log_path;
    return std.fmt.bufPrint(buf, "{s}.crash.txt", .{stem});
}

// ---------------------------------------------------------------------------
// The sink
// ---------------------------------------------------------------------------

/// How much of one formatted log line is kept. A longer line is truncated with
/// a marker rather than dropped: a truncated log line is still evidence.
const line_capacity = 1024;
/// The write buffer in front of the log file.
const file_buffer_capacity = 8192;
/// How much of the end of the log a crash report carries.
pub const log_tail_capacity = 16 * 1024;

/// Why a log file could not be opened. A bad path or a full disk lands here and
/// leaves the app running on stderr, rather than in a crash.
pub const LogFileError = error{CannotCreateLogFile};

/// The one process-wide log destination.
///
/// It is a global because `std.options.logFn` is a bare function with no
/// userdata: the standard library's logging seam leaves the app no way to pass a
/// receiver. Everything it owns is installed once in `main`, before any other
/// module runs, and released on the way out. The mutex is what makes a line
/// from the PTY, render or agent threads arrive whole.
const Sink = struct {
    mutex: Io.Mutex = .init,
    io: Io = undefined,
    /// False until `install` succeeds, so a log call made before `main` — or
    /// after `deinit` — is dropped rather than reading uninitialised memory.
    installed: bool = false,
    level: Level = default_level,

    file: ?File.Writer = null,
    file_buffer: [file_buffer_capacity]u8 = undefined,
    log_path_buffer: [path_capacity]u8 = undefined,
    log_path_len: usize = 0,
    crash_path_buffer: [path_capacity]u8 = undefined,
    crash_path_len: usize = 0,
    /// Bounded in-memory tail used by the test driver without filesystem IO on
    /// the render thread. Bytes are kept in chronological order.
    tail_buffer: [log_tail_capacity]u8 = undefined,
    tail_len: usize = 0,

    /// This run's log file path. Empty when no file was opened.
    fn logPath(self: *const Sink) []const u8 {
        return self.log_path_buffer[0..self.log_path_len];
    }

    /// Where a panic in this run writes its report.
    fn crashPath(self: *const Sink) []const u8 {
        return self.crash_path_buffer[0..self.crash_path_len];
    }

    /// Set the level and start routing to stderr, then open the log file.
    ///
    /// The sink is marked installed before the file is opened: a log file
    /// that cannot be created costs the file, not the run, so stderr keeps
    /// working and the resolved level keeps applying. That is why `install`
    /// reports `LogFileError` without leaving the sink unusable.
    fn install(self: *Sink, io: Io, options: Options) LogFileError!void {
        self.deinit();
        self.io = io;
        self.level = options.level;
        self.installed = true;
        var generated: [path_capacity]u8 = undefined;
        var generated_crash: [path_capacity]u8 = undefined;
        const log_path: []const u8 = if (options.file) |exact| exact else blk: {
            Dir.cwd().createDirPath(io, options.dir) catch return error.CannotCreateLogFile;

            var id_buffer: [path_capacity]u8 = undefined;
            const id = generateRunId(io, &id_buffer) catch return error.CannotCreateLogFile;
            var name_buffer: [path_capacity]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buffer, "{s}.log", .{id}) catch
                return error.CannotCreateLogFile;
            break :blk joinPath(&generated, options.dir, name) catch return error.CannotCreateLogFile;
        };
        const crash_path = crashPathFor(&generated_crash, log_path) catch return error.CannotCreateLogFile;

        // An exact path is the caller's to reuse, so it is truncated. A
        // generated name must never land on an existing file, so it is created
        // exclusively: a collision fails loudly instead of overwriting a
        // concurrent run's log.
        const generated_name = options.file == null;
        const file = Dir.cwd().createFile(io, log_path, .{
            .truncate = !generated_name,
            .exclusive = generated_name,
        }) catch return error.CannotCreateLogFile;

        self.file = file.writerStreaming(io, &self.file_buffer);
        @memcpy(self.log_path_buffer[0..log_path.len], log_path);
        self.log_path_len = log_path.len;
        @memcpy(self.crash_path_buffer[0..crash_path.len], crash_path);
        self.crash_path_len = crash_path.len;
    }

    /// Flush and close the log file. Safe to call more than once.
    fn deinit(self: *Sink) void {
        if (self.file) |*writer| {
            writer.interface.flush() catch {};
            writer.file.close(self.io);
        }
        self.file = null;
        self.log_path_len = 0;
        self.crash_path_len = 0;
        self.tail_len = 0;
        self.installed = false;
    }

    /// Copy at most `destination.len` bytes from the current log tail.
    ///
    /// The caller supplies storage so reading logs never touches the filesystem
    /// or allocates while holding the process-wide log mutex.
    fn copyTail(self: *Sink, destination: []u8) []const u8 {
        if (destination.len == 0) return destination[0..0];
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const count = @min(destination.len, self.tail_len);
        @memcpy(destination[0..count], self.tail_buffer[self.tail_len - count .. self.tail_len]);
        if (count == self.tail_len) return destination[0..count];
        const newline = std.mem.indexOfScalar(u8, destination[0..count], '\n') orelse
            return destination[0..count];
        return destination[newline + 1 .. count];
    }

    fn appendTailLocked(self: *Sink, bytes: []const u8) void {
        if (bytes.len >= self.tail_buffer.len) {
            const suffix = bytes[bytes.len - self.tail_buffer.len ..];
            @memcpy(self.tail_buffer[0..], suffix);
            self.tail_len = self.tail_buffer.len;
            return;
        }
        const overflow = bytes.len -| (self.tail_buffer.len - self.tail_len);
        if (overflow != 0) {
            std.mem.copyForwards(
                u8,
                self.tail_buffer[0 .. self.tail_len - overflow],
                self.tail_buffer[overflow..self.tail_len],
            );
            self.tail_len -= overflow;
        }
        @memcpy(self.tail_buffer[self.tail_len .. self.tail_len + bytes.len], bytes);
        self.tail_len += bytes.len;
    }

    /// Flush and close the log file, leaving the sink installed and routing to
    /// stderr.
    ///
    /// `deinit` is the full teardown; this is what `main` calls on its way out.
    /// The debug allocator's leak report runs *after* `main` returns and reaches
    /// the program through `std.options.logFn`, which is this sink — so a sink
    /// that had gone quiet here would swallow every leak line, and "closes
    /// cleanly with no leaks" would be a claim nobody could check.
    fn closeFile(self: *Sink) void {
        if (self.file) |*writer| {
            writer.interface.flush() catch {};
            writer.file.close(self.io);
        }
        self.file = null;
    }
};

/// The destination installed by `main`. Read by every `std.log` call in the
/// program, and by the panic handler.
var sink: Sink = .{};

fn environGet(ctx: *const anyopaque, key: []const u8) ?[]const u8 {
    const map: *const std.process.Environ.Map = @ptrCast(@alignCast(ctx));
    return map.get(key);
}

/// This process's environment, as an `EnvSource`.
pub fn processEnv(init: std.process.Init) EnvSource {
    return .{ .ctx = init.environ_map, .getFn = environGet };
}

/// Build a fresh, unique run id from the wall clock and the entropy source.
fn generateRunId(io: Io, buf: []u8) ![]const u8 {
    var stamp_buffer: [32]u8 = undefined;
    const now = Io.Clock.real.now(io);
    const stamp = try stampPattern(&stamp_buffer, @divTrunc(now.nanoseconds, std.time.ns_per_s));
    var random: [3]u8 = undefined;
    io.random(&random);
    return runIdPattern(buf, stamp, random);
}

/// Whether `level` passes the sink's current level.
fn enabled(level: Level) bool {
    return sink.installed and @intFromEnum(level) <= @intFromEnum(sink.level);
}

/// `std.options.logFn`. Writes one line to stderr and to the log file.
fn appLog(comptime level: Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    emit(level, scope, format, args);
}

/// Log a line only ever at `debug` level, in the `.sensitive` scope.
///
/// This is the only sanctioned way to put terminal contents, clipboard data,
/// credentials or agent prompts into the log (CONDUIT.md §11, AGENTS.md). It
/// takes no level: the level is `debug`, unconditionally, and `emit` refuses to
/// write the `.sensitive` scope above `debug` even when some other caller asks
/// it to. A caller therefore cannot move such content above debug by choosing
/// `--log-level` or by setting `CONDUIT_LOG_LEVEL`.
pub fn sensitiveLog(comptime format: []const u8, args: anytype) void {
    emit(.debug, .sensitive, format, args);
}

/// Format and dispatch one log line.
fn emit(comptime level: Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    // The clamp is redundant while `sensitiveLog` is the only caller of the
    // `.sensitive` scope, and that is exactly why it stays: the safety property
    // keeps holding when that is no longer true.
    if (scope == .sensitive and level != .debug) return;
    if (!enabled(level)) return;

    var buffer: [line_capacity]u8 = undefined;
    var writer: Writer = .fixed(&buffer);
    writeTimestamp(&writer, sink.io) catch {};
    writer.writeByte(' ') catch {};
    writer.writeAll(level.asText()) catch {};
    writer.writeByte('(') catch {};
    writer.writeAll(@tagName(scope)) catch {};
    writer.writeAll("): ") catch {};
    writer.print(format, args) catch {};
    // A line that filled the buffer has no room for the newline, so the last
    // byte becomes it. The line is truncated either way; this keeps every line
    // in the file terminated, which is what makes the log tail readable.
    if (writer.end == buffer.len) {
        buffer[buffer.len - 1] = '\n';
    } else {
        writer.writeByte('\n') catch {};
    }

    const line = writer.buffered();
    sink.mutex.lockUncancelable(sink.io);
    defer sink.mutex.unlock(sink.io);
    sink.appendTailLocked(line);
    writeStderr(level, line);
    if (sink.file) |*file| {
        file.interface.writeAll(line) catch {};
        file.interface.flush() catch {};
    }
}

/// The same line to stderr, with the level in colour, matching what the
/// standard library's own default log function looks like.
fn writeStderr(level: Level, line: []const u8) void {
    var buffer: [line_capacity]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();

    stderr.setColor(switch (level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    stderr.setColor(.bold) catch {};
    stderr.writer.writeAll(line) catch {};
    stderr.setColor(.reset) catch {};
    stderr.writer.flush() catch {};
}

/// `2026-10-04T21:38:00.123Z`, from the wall clock in UTC.
fn writeTimestamp(writer: *Writer, io: Io) Writer.Error!void {
    const now = Io.Clock.real.now(io);
    const epoch = std.time.epoch.EpochSeconds{
        .secs = @intCast(@max(@divTrunc(now.nanoseconds, std.time.ns_per_s), 0)),
    };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    const year: u16 = year_day.year;
    const month: u8 = @intCast(@intFromEnum(month_day.month));
    const day: u32 = @intCast(month_day.day_index + 1);
    const hours: u32 = day_seconds.getHoursIntoDay();
    const minutes: u32 = day_seconds.getMinutesIntoHour();
    const seconds: u32 = day_seconds.getSecondsIntoMinute();
    const millis: u32 = @intCast(@divTrunc(@mod(now.nanoseconds, std.time.ns_per_s), std.time.ns_per_ms));
    try writer.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        year,
        month,
        day,
        hours,
        minutes,
        seconds,
        millis,
    });
}

// ---------------------------------------------------------------------------
// Crash reports
// ---------------------------------------------------------------------------

/// A re-entry guard: a fault inside the reporter must not start another one,
/// and `std.debug.defaultPanic` is what actually stops the process.
var reporting_crash = std.atomic.Value(bool).init(false);

/// What a crash report is written from. `log_path` and `crash_path` are `null`
/// when logging was never installed, which is the case for a fault before
/// `main` reaches `install`.
pub const CrashReport = struct {
    message: []const u8,
    log_path: ?[]const u8 = null,
    crash_path: ?[]const u8 = null,
    first_address: ?usize = null,
};

/// Write a crash report: the panic message, the stack trace, and the tail of
/// this run's log.
///
/// The report goes to `crash_path`, which is the log file's own name with a
/// `.crash.txt` suffix, so `--print-log-path` is enough to find both. Every
/// failure here is swallowed on purpose: the process is already dying, the
/// report is a best effort, and a second fault inside the reporter would hide
/// the first. `std.debug.defaultPanic` still prints the message and the trace
/// to stderr, so a report that could not be written costs the log tail and
/// nothing else.
pub fn writeCrashReport(io: Io, report: CrashReport) void {
    if (reporting_crash.swap(true, .acq_rel)) return;
    defer reporting_crash.store(false, .release);

    const path = report.crash_path orelse return;
    const file = Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer file.close(io);

    var buffer: [file_buffer_capacity]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    const out = &writer.interface;

    var target_buffer: [64]u8 = undefined;
    out.print("conduit crash report\n", .{}) catch {};
    out.print("version: {s}\n", .{version}) catch {};
    out.print("target: {s}\n", .{buildTarget(&target_buffer) catch "unknown"}) catch {};
    out.print("log file: {s}\n", .{report.log_path orelse "(none)"}) catch {};
    out.print("panic: {s}\n", .{report.message}) catch {};
    out.writeAll("\n--- stack trace ---\n") catch {};
    std.debug.writeCurrentStackTrace(
        .{ .first_address = report.first_address },
        .{ .writer = out, .mode = .no_color },
    ) catch {};
    out.writeAll("\n--- log tail ---\n") catch {};

    var tail: [log_tail_capacity]u8 = undefined;
    if (readLogTail(io, report.log_path orelse "", &tail)) |bytes| {
        out.writeAll(bytes) catch {};
    } else {
        out.writeAll("(no log tail available)\n") catch {};
    }
    out.flush() catch {};
}

/// The last `buffer.len` bytes of `path`, trimmed to start at a line boundary
/// so the tail reads as whole lines rather than as a fragment of one.
fn readLogTail(io: Io, path: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len == 0 or buffer.len == 0) return null;
    const file = Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const length = file.length(io) catch return null;
    if (length == 0) return null;
    const start = if (length > buffer.len) length - buffer.len else 0;
    // `readPositionalAll` insists on filling the whole buffer, so the buffer is
    // trimmed to what is actually there. A log shorter than the buffer is the
    // common case at the moment of an early crash.
    const want: usize = @intCast(@min(length - start, buffer.len));
    const read = file.readPositionalAll(io, buffer[0..want], start) catch return null;
    const window = buffer[0..read];
    if (start == 0) return window;
    const newline = std.mem.indexOfScalar(u8, window, '\n') orelse return window;
    return window[newline + 1 ..];
}

/// The panic handler: write the report, then hand over to the standard library
/// so the message and the trace still reach stderr and the process still aborts.
fn onPanic(message: []const u8, first_trace_addr: ?usize) noreturn {
    const io = if (sink.installed) sink.io else std.Options.debug_io;
    writeCrashReport(io, .{
        .message = message,
        .log_path = if (sink.installed) sink.logPath() else null,
        .crash_path = if (sink.installed) sink.crashPath() else null,
        .first_address = first_trace_addr,
    });
    std.debug.defaultPanic(message, first_trace_addr);
}

// ---------------------------------------------------------------------------
// The window, the surface and the loop
// ---------------------------------------------------------------------------

/// The colour the surface is cleared to before anything is drawn.
///
/// This is the terminal background until `theme` owns one. A surface that has
/// never had anything drawn into it is this colour, so a window that has just
/// opened shows a terminal's background rather than a hole.
pub const background: render.Rgba = .{ .r = 0x16, .g = 0x1a, .b = 0x22 };

/// The window title. A window manager's task list, a screenshot's header and a
/// log reader all name the app from here.
pub const window_title: [:0]const u8 = "conduit";

/// What the loop should do next.
///
/// Render-on-demand is one bit: the loop draws when something changed what should
/// be on screen — the first frame, a resize, a display-scale change, an expose —
/// and does nothing at all otherwise. `force` is the one exception, and it exists
/// so the cost of this can be measured against the cost of not doing it.
pub const Scheduler = struct {
    /// Whether what is on the surface no longer matches what the app wants there.
    dirty: bool,
    /// Whether to draw every iteration whatever else is true.
    force: bool,
    /// How many frames have been drawn. A count is how `--self-test` shows that an
    /// idle window drew none.
    frames: u64,

    /// A scheduler with one frame owed: there is nothing on the surface until one
    /// is drawn, so the very first iteration must draw.
    pub fn init(force: bool) Scheduler {
        return .{ .dirty = true, .force = force, .frames = 0 };
    }

    /// Something happened that changes what the surface should look like.
    pub fn invalidate(self: *Scheduler) void {
        self.dirty = true;
    }

    /// Whether this iteration of the loop draws a frame.
    pub fn shouldDraw(self: *const Scheduler) bool {
        return self.dirty or self.force;
    }

    /// Record that a frame has been drawn. The surface is clean again until
    /// something invalidates it.
    pub fn drawn(self: *Scheduler) void {
        self.dirty = false;
        self.frames += 1;
    }
};

/// The surface size a window state implies.
fn surfaceSize(state: platform.State) render.Size {
    return .{ .width = state.surface.width_px, .height = state.surface.height_px };
}

/// A font manager and a child process, built on a worker thread.
///
/// Ownership: the worker allocates with the app's allocator and publishes what
/// it built; the render thread takes those values once `finished` says so, and
/// nothing touches them in between. The publish is a release store and every
/// read an acquire, which is what makes the `Manager` and the `Pty` visible to
/// the thread that takes them without a second lock.
///
/// `io` is used from both threads, which is what Zig 0.16's `Io` is for —
/// `std.Io.Threaded` documents itself as thread-safe, and the only IO here is
/// listing font directories and opening files.
const Load = struct {
    allocator: Allocator,
    io: Io,
    /// The face to build, or null when this job is only spawning a child.
    font_request: ?font.Request = null,
    /// The child to start, or null when this job is only loading a face.
    spawn: ?pty.SpawnRequest = null,
    /// A copied cwd used by `spawn`, or null when the request borrows the
    /// workspace's stable default. A newly tracked terminal cwd may change on
    /// the next feed, so an asynchronous worker may never borrow it.
    spawn_cwd: ?[]u8 = null,
    /// Owned argv used by `spawn` instead of the app-level child spec, or null
    /// when the request borrows that stable spec. A file-reference editor is
    /// built per job from terminal-derived text and dies with the job.
    spawn_argv: ?[][]const u8 = null,
    /// The stable session that requested `spawn`. Selection may change while
    /// the worker runs, but ownership of its result may not.
    spawn_session_id: ?session.SessionId = null,
    /// The registry workspace that owns a spawn result. Session identifiers
    /// are workspace-local and are not sufficient attribution on their own.
    workspace_key: ?workspace.WorkspaceKey = null,
    /// This job spawned a transactional scratchpad replacement rather than a
    /// child for a starting session.
    scratchpad_replacement: bool = false,
    /// Borrowed from the workspace that owns this job's target session. The
    /// owner outlives and joins the worker before releasing its context.
    execution_context: ?workspace.ExecutionContext.Ref = null,
    /// Zero while the worker runs, one once the values below may be read.
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fonts: ?font.Manager = null,
    child: ?pty.Pty = null,
    /// Failures as names rather than as errors: a log line outlives the error
    /// set that produced it, and the app carries on either way.
    font_failure: ?[]const u8 = null,
    spawn_failure: ?[]const u8 = null,
    thread: ?std.Thread = null,

    fn start(self: *Load) !void {
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }

    fn finished(self: *const Load) bool {
        return self.state.load(.acquire) != 0;
    }

    /// Release the copied cwd and owned argv a spawn job carried. Safe on
    /// every completion and failure path once the worker is no longer running.
    fn freeSpawnInputs(self: *Load) void {
        if (self.spawn_cwd) |cwd| self.allocator.free(cwd);
        self.spawn_cwd = null;
        if (self.spawn_argv) |argv| freeEntries(self.allocator, argv);
        self.spawn_argv = null;
    }

    fn work(worker_context: *anyopaque) void {
        const self: *Load = @ptrCast(@alignCast(worker_context));
        if (self.font_request) |request| {
            const fonts = font.Manager.init(self.allocator, self.io, request);
            if (fonts) |loaded| {
                self.fonts = loaded;
            } else |err| {
                self.font_failure = @errorName(err);
            }
        }
        if (self.spawn) |request| {
            const context = self.execution_context orelse {
                self.spawn_failure = "MissingExecutionContext";
                self.state.store(1, .release);
                return;
            };
            const child = context.spawn(request);
            if (child) |spawned| {
                self.child = spawned;
            } else |err| {
                self.spawn_failure = @errorName(err);
            }
        }
        self.state.store(1, .release);
    }
};

/// What a child process is started with: its program, its environment and its
/// size.
///
/// Ownership: every string is allocated with the app's allocator and freed by
/// `deinit`, and the child is given copies of what it needs, so the whole
/// struct can go once the child has been spawned.
///
/// Conduit never hands a child the process's own environment: a spawn belongs
/// to an execution context (P7), so the environment here is built from what the
/// run was configured with plus the handful of variables a shell notices are
/// missing.
const ChildSpec = struct {
    allocator: Allocator,
    argv: [][]const u8,
    env: [][]const u8,

    fn deinit(self: *ChildSpec) void {
        freeEntries(self.allocator, self.argv);
        freeEntries(self.allocator, self.env);
    }

    /// The environment a child gets when the process itself was started with
    /// none, because an empty `PATH` means "find nothing".
    const fallback_path = "/usr/local/bin:/usr/bin:/bin";

    fn build(allocator: Allocator, io: Io, env: EnvSource, options: Options) !ChildSpec {
        return buildIn(allocator, io, env, options, null);
    }

    /// Build the workspace scratchpad's interactive shell independently of
    /// every run/check command. A scratchpad is a user's persistent terminal,
    /// never a second copy of `--command` or a deterministic test peer.
    fn buildInteractive(
        allocator: Allocator,
        io: Io,
        env: EnvSource,
        no_shell_integration: bool,
        shell_override: ?[]const u8,
    ) !ChildSpec {
        var argv: std.ArrayList([]const u8) = .empty;
        errdefer freeEntries(allocator, argv.items);
        var variables: std.ArrayList([]const u8) = .empty;
        errdefer freeEntries(allocator, variables.items);

        const shell = shell_override orelse env.get("SHELL") orelse "/bin/sh";
        try put(allocator, &argv, shell);
        try variable(allocator, &variables, "TERM", "xterm-256color");
        try variable(allocator, &variables, "COLORTERM", "truecolor");
        try variable(allocator, &variables, "TERM_PROGRAM", "conduit");
        try variable(allocator, &variables, "PATH", env.get("PATH") orelse fallback_path);
        try variable(allocator, &variables, "HOME", env.get("HOME") orelse "/");
        try variable(allocator, &variables, "LANG", env.get("LANG") orelse "C.UTF-8");

        if (!no_shell_integration) {
            if (ShellKind.detect(shell)) |kind| {
                try injectShellIntegration(allocator, io, env, kind, null, &argv, &variables);
            }
        }

        return .{
            .allocator = allocator,
            .argv = try argv.toOwnedSlice(allocator),
            .env = try variables.toOwnedSlice(allocator),
        };
    }

    /// `build`, with the directory the integration scripts are written to
    /// chosen by the caller. A test passes its own temporary directory; the app
    /// passes null and gets `shellIntegrationDir`.
    fn buildIn(allocator: Allocator, io: Io, env: EnvSource, options: Options, integration_root: ?[]const u8) !ChildSpec {
        var argv: std.ArrayList([]const u8) = .empty;
        errdefer freeEntries(allocator, argv.items);
        var variables: std.ArrayList([]const u8) = .empty;
        errdefer freeEntries(allocator, variables.items);

        // The PTY checks run fixed children, so what the program receives is
        // known and nothing of the user's shell configuration is involved.
        const command = if (options.run.clipboard_test)
            clipboard_test_script
        else if (options.run.ime_test)
            ime_test_script
        else if (options.run.tabs_test)
            tabs_test_script
        else if (options.run.panes_test)
            panes_test_script
        else if (options.run.palette_test)
            palette_test_script
        else if (options.run.workspaces_test)
            workspaces_test_script
        else if (options.run.links_test)
            links_test_script
        else if (options.run.search_test)
            search_test_script
        else if (options.run.menu_test)
            menu_test_script
        else
            options.run.command;
        const shell: ?[]const u8 = if (command) |line| blk: {
            // `/bin/sh` rather than `$SHELL`: a line to run is a script, and a
            // script should not depend on which login shell the person running
            // it happens to have. A script is not an interactive shell, so it
            // gets no shell integration either.
            try put(allocator, &argv, "/bin/sh");
            try put(allocator, &argv, "-c");
            try put(allocator, &argv, line);
            break :blk null;
        } else env.get("SHELL") orelse "/bin/sh";
        if (shell) |program| try put(allocator, &argv, program);

        // The two that decide what a program draws and how much colour it may
        // use, then the three it cannot start without.
        try variable(allocator, &variables, "TERM", "xterm-256color");
        try variable(allocator, &variables, "COLORTERM", "truecolor");
        try variable(allocator, &variables, "TERM_PROGRAM", "conduit");
        try variable(allocator, &variables, "PATH", env.get("PATH") orelse fallback_path);
        try variable(allocator, &variables, "HOME", env.get("HOME") orelse "/");
        try variable(allocator, &variables, "LANG", env.get("LANG") orelse "C.UTF-8");

        if (shell) |program| if (!options.run.no_shell_integration) {
            if (ShellKind.detect(program)) |kind| {
                try injectShellIntegration(allocator, io, env, kind, integration_root, &argv, &variables);
            }
        };

        return .{
            .allocator = allocator,
            .argv = try argv.toOwnedSlice(allocator),
            .env = try variables.toOwnedSlice(allocator),
        };
    }

    fn put(allocator: Allocator, list: *std.ArrayList([]const u8), text: []const u8) !void {
        try list.append(allocator, try allocator.dupe(u8, text));
    }

    fn variable(allocator: Allocator, list: *std.ArrayList([]const u8), key: []const u8, value: []const u8) !void {
        try list.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value }));
    }
};

/// Free a list of owned strings and the list itself. An empty slice is the
/// literal `&.{}`, which owns nothing, so it is not freed.
fn freeEntries(allocator: Allocator, entries: [][]const u8) void {
    if (entries.len == 0) return;
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

/// The scripts `build.zig` embeds from `assets/shell-integration/`.
const shell_scripts = @import("shell-integration");

/// The shells Conduit has an integration script for. Anything else gets
/// nothing: Conduit never guesses (see `assets/shell-integration/README.md`).
const ShellKind = enum {
    bash,
    zsh,
    fish,

    /// The shell a program path names, judged by its file name only. A login
    /// shell's leading `-` is not stripped because Conduit never starts one.
    fn detect(program: []const u8) ?ShellKind {
        const name = std.fs.path.basename(program);
        if (std.mem.eql(u8, name, "bash")) return .bash;
        if (std.mem.eql(u8, name, "zsh")) return .zsh;
        if (std.mem.eql(u8, name, "fish")) return .fish;
        return null;
    }
};

/// Where the scripts are written for a shell to read: a private directory
/// under the platform temporary directory, falling back to the build cache.
/// The scripts are the same bytes every run, so the directory is reused.
fn shellIntegrationDir(buffer: []u8, env: EnvSource) ![]const u8 {
    const base = firstEnv(env, temp_dir_vars[0..]) orelse fallback_log_dir;
    return std.fmt.bufPrint(buffer, "{s}{c}conduit-shell-integration", .{ base, std.fs.path.sep });
}

/// Write the embedded scripts under `root`, in the layout each shell expects:
/// `bash/conduit.bash`, `zsh/.zshenv` + `zsh/conduit.zsh`, and
/// `fish/vendor_conf.d/conduit.fish` (fish finds that through `XDG_DATA_DIRS`).
fn writeShellScripts(io: Io, root: []const u8) !void {
    var path: [path_capacity]u8 = undefined;
    const files = [_]struct { dir: []const u8, name: []const u8, data: []const u8 }{
        .{ .dir = "bash", .name = "conduit.bash", .data = shell_scripts.bash },
        .{ .dir = "zsh", .name = ".zshenv", .data = shell_scripts.zsh_env },
        .{ .dir = "zsh", .name = "conduit.zsh", .data = shell_scripts.zsh },
        .{ .dir = "fish" ++ std.fs.path.sep_str ++ "vendor_conf.d", .name = "conduit.fish", .data = shell_scripts.fish },
    };
    for (files) |file| {
        const dir = try std.fmt.bufPrint(&path, "{s}{c}{s}", .{ root, std.fs.path.sep, file.dir });
        try Dir.cwd().createDirPath(io, dir);
        var full: [path_capacity]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&full, "{s}{c}{s}", .{ dir, std.fs.path.sep, file.name });
        try Dir.cwd().writeFile(io, .{ .sub_path = sub_path, .data = file.data });
    }
}

/// Add what `kind` needs to load Conduit's integration to a child's `argv` and
/// environment. Writing the scripts can fail (a read-only temporary
/// directory); that leaves the shell exactly as it would have started without
/// integration, and says so, rather than failing the spawn.
fn injectShellIntegration(
    allocator: Allocator,
    io: Io,
    env: EnvSource,
    kind: ShellKind,
    integration_root: ?[]const u8,
    argv: *std.ArrayList([]const u8),
    variables: *std.ArrayList([]const u8),
) !void {
    var root_buffer: [path_capacity]u8 = undefined;
    const relative = integration_root orelse try shellIntegrationDir(&root_buffer, env);
    writeShellScripts(io, relative) catch |err| {
        log.warn("shell integration is off for this shell: its scripts could not be written ({s})", .{@errorName(err)});
        return;
    };
    // The shell starts in its own working directory, not Conduit's, so every
    // path handed to it must be absolute: a relative ENV or ZDOTDIR names a
    // file that does not exist from where the shell stands, and the shell then
    // loads nothing without saying so.
    const root = Dir.cwd().realPathFileAlloc(io, relative, allocator) catch |err| {
        log.warn("shell integration is off for this shell: its directory could not be resolved ({s})", .{@errorName(err)});
        return;
    };
    defer allocator.free(root);

    try ChildSpec.variable(allocator, variables, "CONDUIT_SHELL_INTEGRATION_DIR", root);
    var path: [path_capacity]u8 = undefined;
    switch (kind) {
        // POSIX mode makes an interactive bash read `ENV` instead of its usual
        // startup files; the script turns POSIX mode back off and replays them.
        .bash => {
            try ChildSpec.put(allocator, argv, "--posix");
            const script = try std.fmt.bufPrint(&path, "{s}{c}bash{c}conduit.bash", .{ root, std.fs.path.sep, std.fs.path.sep });
            try ChildSpec.variable(allocator, variables, "ENV", script);
            try ChildSpec.variable(allocator, variables, "CONDUIT_BASH_INJECT", "1");
        },
        // `ZDOTDIR` points at the integration directory, and the user's own
        // value — or its absence, as an empty value — rides along so the
        // script's `.zshenv` can put it back before anything else runs.
        .zsh => {
            try ChildSpec.variable(allocator, variables, "CONDUIT_ZSH_ZDOTDIR", env.get("ZDOTDIR") orelse "");
            const dir = try std.fmt.bufPrint(&path, "{s}{c}zsh", .{ root, std.fs.path.sep });
            try ChildSpec.variable(allocator, variables, "ZDOTDIR", dir);
        },
        // Untested by decision (see the README). fish reads `vendor_conf.d`
        // from every directory in `XDG_DATA_DIRS`, and the script removes this
        // one again so programs the shell starts see the user's value.
        .fish => {
            const dir = try std.fmt.bufPrint(&path, "{s}{c}fish", .{ root, std.fs.path.sep });
            try ChildSpec.variable(allocator, variables, "CONDUIT_SHELL_INTEGRATION_XDG_DIR", dir);
            var data_dirs: [path_capacity]u8 = undefined;
            const existing = env.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
            const joined = try std.fmt.bufPrint(&data_dirs, "{s}:{s}", .{ dir, existing });
            try ChildSpec.variable(allocator, variables, "XDG_DATA_DIRS", joined);
        },
    }
}

/// The grid that fits a surface of `size` at a given cell size, in whole
/// cells. The grid is integral and the surface is not, so the leftover pixels
/// along the right and bottom edges are simply not part of the terminal.
fn gridSizeFor(cell: font.CellSize, size: render.Size) !term.GridSize {
    const fits = cell.cellsPer(size.width, size.height);
    // At least one cell in each direction: a surface smaller than a single cell
    // is a window with a terminal in it, not a terminal of no cells, and every
    // grid calculation divides by the cell size.
    return try term.GridSize.init(
        @intCast(@max(1, @min(fits.columns, std.math.maxInt(u16)))),
        @intCast(@max(1, @min(fits.rows, std.math.maxInt(u16)))),
    );
}

/// The size a terminal's cells are rasterised at, in points, before the display
/// scale. The scale multiplies it, so a 2x display rasterises 28px glyphs
/// rather than enlarging 14px ones — which is the whole of TASK-11's HiDPI
/// story, and why the grid never has to scale anything itself.
const font_points: f32 = 14.0;

/// The glyph atlas, in pixels. `font` allocates it and `render` uploads it as
/// one texture, so both are told the same number.
const atlas_width_px: u32 = 1024;
const atlas_height_px: u32 = 1024;

/// How many bytes are copied out of the child per frame. A program's output
/// arrives in whatever sizes the pipe hands over, and this buffer is never
/// resized, so a frame never allocates.
const pty_read_capacity = 64 * 1024;

/// How long the cursor is on, and how long it is off, in nanoseconds.
const blink_period_ns: i128 = 600 * std.time.ns_per_ms;

/// How long the loop blocks for a window event when something outside the
/// queue can change the screen, in milliseconds. It bounds how long a byte
/// from the child can wait for a frame.
const idle_tick_ms: i32 = 16;

/// Whether a run spawns a child at all. The checks that need a grid that is
/// not moving under them ask for none; PTY-facing checks ask for their own,
/// because terminal input is only proved by what a program reads.
fn wantsChild(options: Options) bool {
    if (options.run.ui_test or options.run.sidebar_test) return false;
    if (options.run.clipboard_test or options.run.ime_test or options.run.tabs_test or
        options.run.panes_test or options.run.palette_test or options.run.workspaces_test or
        options.run.links_test or options.run.search_test or options.run.menu_test) return true;
    return !options.run.no_child and !options.run.self_test and !options.run.grid_test and
        !options.run.scroll_test and !options.run.mouse_test and !options.run.ui_test and
        !options.run.sidebar_test;
}

/// Built-in checks must not source the user's shell configuration through the
/// workspace scratchpad. They still start and pump the reserved session, but
/// use a deterministic plain shell so late rc/integration output cannot alter
/// an unrelated pixel or idle-work measurement.
fn usesDeterministicScratchpad(options: Options) bool {
    const run = options.run;
    return run.self_test or run.grid_test or run.scroll_test or run.mouse_test or
        run.clipboard_test or run.ui_test or run.ime_test or run.sidebar_test or
        run.tabs_test or run.panes_test or run.scratchpad_test or run.palette_test or
        run.workspaces_test or run.links_test or run.search_test or run.menu_test or
        run.driver_test;
}

/// The two clipboards a user gesture reaches: the standard one (the copy and
/// paste chords) and Linux's primary selection (middle click).
const ClipboardTarget = enum { standard, primary };

const clipboard_copy_action = "clipboard.copy";
const clipboard_paste_action = "clipboard.paste";
const ui_test_activate_action = "ui-test.activate";
const sidebar_toggle_action = "sidebar.toggle";
const sidebar_narrow_action = "sidebar.narrow";
const sidebar_widen_action = "sidebar.widen";
const sidebar_focus_action = "sidebar.focus";
const workspace_activate_action = "workspace.activate";
const workspace_create_action = "workspace.create";
const workspace_rename_action = "workspace.rename";
const workspace_switch_action = "workspace.switch";
const workspace_close_action = "workspace.close";
const workspace_close_confirm_action = "workspace.close.confirm";
const workspace_close_cancel_action = "workspace.close.cancel";
const tab_activate_action = "tab.activate";
const tab_new_action = "tab.new";
const tab_close_action = "tab.close";
const tab_close_confirm_action = "tab.close.confirm";
const tab_close_cancel_action = "tab.close.cancel";
const tab_rename_action = "tab.rename";
const tab_rename_commit_action = "tab.rename.commit";
const tab_rename_cancel_action = "tab.rename.cancel";
const tab_previous_action = "tab.previous";
const tab_next_action = "tab.next";
const tab_goto_action = "tab.goto";
const tab_move_action = "tab.move";
const tab_reorder_action = "tab.reorder";
const sidebar_resize_action = "sidebar.resize";
const pane_activate_action = "pane.activate";
const pane_split_action = "pane.split";
const pane_focus_action = "pane.focus";
const pane_resize_action = "pane.resize";
const pane_zoom_action = "pane.zoom";
const pane_close_action = "pane.close";
const scratchpad_toggle_50_action = "scratchpad.toggle-50";
const scratchpad_toggle_90_action = "scratchpad.toggle-90";
const scratchpad_restart_action = "scratchpad.restart";
const scratchpad_hide_action = "scratchpad.hide";
const palette_open_action = "palette.open";
const palette_activate_action = "palette.activate";
const terminal_open_link_action = "terminal.open-link";
const search_open_action = "search.open";
const search_close_action = "search.close";
const search_next_action = "search.next";
const search_previous_action = "search.previous";
const search_case_action = "search.toggle-case";
const search_regex_action = "search.toggle-regex";
const search_activate_match_action = "search.activate-match";
const terminal_context_menu_action = "terminal.context-menu";

const tab_move_choices = [_]inputmod.PaletteChoice{
    .{ .label = "Up", .value = "up" },
    .{ .label = "Down", .value = "down" },
};

const pane_split_choices = [_]inputmod.PaletteChoice{
    .{ .label = "Right", .value = "right" },
    .{ .label = "Down", .value = "down" },
};

const pane_direction_choices = [_]inputmod.PaletteChoice{
    .{ .label = "Left", .value = "left" },
    .{ .label = "Right", .value = "right" },
    .{ .label = "Up", .value = "up" },
    .{ .label = "Down", .value = "down" },
};

const ScratchpadPresentation = enum {
    hidden,
    fifty,
    ninety,

    fn percent(self: ScratchpadPresentation) u32 {
        return switch (self) {
            .hidden => 0,
            .fifty => 50,
            .ninety => 90,
        };
    }
};

const sidebar_default_width: u16 = 24;
const sidebar_min_width: u16 = 12;
const sidebar_max_width: u16 = 48;
const sidebar_resize_step: u16 = 2;
const sidebar_element_capacity: usize = 260;
const terminal_link_capacity: usize = 128;
const terminal_link_row_bytes: usize = 64 * 1024;
const terminal_link_osc_capacity: usize = 256;
const terminal_link_frame_bytes: usize = terminal_link_capacity * link.default_max_target_bytes * 2;
const terminal_link_semantic_capacity: usize = 128;
const search_match_capacity: usize = 128;
const search_highlight_capacity: usize = 256;
const search_semantic_capacity: usize = 64;
const search_scratch_capacity: usize = 1024 * 1024;
const search_tick_budget: usize = 4;
const search_candidate_budget: usize = 32;
const semantic_element_capacity: usize = sidebar_element_capacity + terminal_link_capacity +
    search_highlight_capacity + 12;
const pane_ui_capacity: usize = 64;
const tab_name_capacity: usize = 256;
const palette_input_capacity: usize = 256;
const palette_visible_rows: usize = 10;
const palette_action_capacity: usize = 48;
const palette_semantic_capacity: usize = 48;
const palette_label_capacity: usize = 192;
const workspace_semantic_capacity: usize = 96;

const PaletteStep = union(enum) {
    closed,
    commands,
    input: usize,
    choices: struct {
        definition_index: usize,
        selected: usize,
    },
};

const SearchMode = enum {
    literal,
    regex,
};

const SearchPageActivation = enum { first, last };

const SearchBarLayout = struct {
    bounds: ui.Rect,
    query: ui.Rect,
    detail: ?ui.Rect,
    bordered: bool,
};

/// Search must keep its text target visible whenever the canvas has even one
/// cell. The full box is useful at ordinary sizes; a compact bar spends no
/// cells on chrome and drops its optional detail row when height is scarce.
fn calculateSearchBarLayout(canvas: ui.Rect) ?SearchBarLayout {
    if (canvas.width == 0 or canvas.height == 0) return null;

    const bordered = canvas.width >= 42 and canvas.height >= 4;
    const width = @min(@as(u32, 72), canvas.width);
    const height = @min(@as(u32, 4), canvas.height);
    const bounds: ui.Rect = .{
        .x = canvas.x +| (canvas.width - width),
        .y = canvas.y,
        .width = width,
        .height = height,
    };
    if (!bordered) return .{
        .bounds = bounds,
        .query = .{ .x = bounds.x, .y = bounds.y, .width = bounds.width, .height = 1 },
        .detail = if (bounds.height >= 2) .{
            .x = bounds.x,
            .y = bounds.y + 1,
            .width = bounds.width,
            .height = 1,
        } else null,
        .bordered = false,
    };

    return .{
        .bounds = bounds,
        .query = .{
            .x = bounds.x + 2,
            .y = bounds.y + 1,
            .width = bounds.width - 4,
            .height = 1,
        },
        .detail = .{
            .x = bounds.x + 2,
            .y = bounds.y + 2,
            .width = bounds.width - 4,
            .height = 1,
        },
        .bordered = true,
    };
}

/// One bounded materialization window. A replacement page uses the inactive
/// slot so the current selection remains usable until at least one adjacent
/// match has actually been found.
const SearchPageScan = struct {
    cursor: term.SearchCursor,
    slot: usize,
    count: usize = 0,
    activation: SearchPageActivation,
    allow_wrap: bool,
    wrapped: bool = false,
};

/// Existing renderer checks predate the workspace shell and retain their
/// fixed full-terminal geometry. The sidebar check and ordinary runs exercise
/// the production inset instead.
fn sidebarEnabled(options: Options) bool {
    return !(options.run.self_test or options.run.grid_test or options.run.scroll_test or
        options.run.mouse_test or options.run.clipboard_test or options.run.ui_test or
        options.run.ime_test or options.run.links_test or options.run.search_test or
        options.run.menu_test or options.run.driver_test);
}

fn sidebarStartsVisible(options: Options) bool {
    return sidebarEnabled(options);
}

fn sidebarColumns(total_cols: u16, preferred: u16, visible: bool) u16 {
    if (!visible or total_cols <= 1) return 0;
    const available = total_cols - 1;
    const bounded = @min(@max(preferred, sidebar_min_width), sidebar_max_width);
    return @min(bounded, available);
}

/// Why a copy did not happen. Logged by name; the text never is.
const CopyError = platform.ClipboardError || error{NothingSelected};

/// Why a paste did not happen. Logged by name; the text never is.
const PasteFailure = platform.ClipboardError || term.PasteError || error{
    /// The previous paste has not gone out yet. One at a time keeps a frame's
    /// memory bounded by one clipboard rather than by however many presses.
    PasteInFlight,
};

/// What a paste did, by size.
const PasteOutcome = union(enum) {
    /// Encoded and queued for `pumpChild`; this many bytes will be written.
    queued: usize,
    /// Nothing was sent: this many bytes of multi-line text into a program
    /// without bracketed paste wait for a confirmation M1 cannot ask for.
    confirmation_required: usize,
};

/// The native clipboard an OSC 52 selector names.
///
/// `s` (selection) and `p` (primary) are both the primary selection where one
/// exists: X11 and Wayland have exactly one besides the clipboard. Elsewhere
/// they are refused rather than quietly redirected to the clipboard a program
/// did not name.
fn nativeTarget(location: term.ClipboardLocation) term.ClipboardAccessError!ClipboardTarget {
    return switch (location) {
        .standard => .standard,
        .selection, .primary => if (platform.primary_selection_supported) .primary else error.Unsupported,
    };
}

fn accessError(err: platform.ClipboardError) term.ClipboardAccessError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PayloadTooLarge => error.PayloadTooLarge,
        error.InvalidText => error.InvalidText,
        error.ClipboardReadFailed, error.ClipboardWriteFailed => error.Unavailable,
    };
}

/// `term.ClipboardAccess.read_fn`: an OSC 52 read that policy allowed. The
/// caller owns the returned text, allocated with `alloc`.
fn readNativeClipboard(_: ?*anyopaque, location: term.ClipboardLocation, alloc: Allocator) term.ClipboardAccessError![]u8 {
    return switch (try nativeTarget(location)) {
        .standard => platform.getClipboardText(alloc),
        .primary => platform.getPrimarySelectionText(alloc),
    } catch |err| accessError(err);
}

/// `term.ClipboardAccess.write_fn`: an OSC 52 write that policy allowed.
/// `text` is borrowed for the call.
fn writeNativeClipboard(_: ?*anyopaque, location: term.ClipboardLocation, text: []const u8, alloc: Allocator) term.ClipboardAccessError!void {
    return switch (try nativeTarget(location)) {
        .standard => platform.setClipboardText(alloc, text),
        .primary => platform.setPrimarySelectionText(alloc, text),
    } catch |err| accessError(err);
}

/// What `--clipboard-test` observes of the child, in the order it happened.
///
/// Ownership: both lists are allocated with the app's allocator and freed by
/// `deinit`. Only fixtures the check wrote itself ever pass through it.
const ClipboardTrace = struct {
    /// Every byte `writeToChild` handed the child, in order.
    sent: std.ArrayList(u8) = .empty,
    /// Every byte the child wrote back, in order.
    received: std.ArrayList(u8) = .empty,
    /// The last OSC 52 permission request the app saw.
    last_permission: ?term.PermissionRequest = null,

    fn deinit(self: *ClipboardTrace, allocator: Allocator) void {
        self.sent.deinit(allocator);
        self.received.deinit(allocator);
    }
};

/// What one platform text-input event changed in the app's composition state.
///
/// Committed text borrows the event's payload and must be staged before the
/// next platform event is pumped. The other two input-method events have
/// already copied everything the app needs into `Composition`.
const InputMethodOutcome = union(enum) {
    unrelated,
    preedit,
    candidates,
    committed: []const u8,
};

/// Route the text-input part of the platform event stream into one composition.
///
/// Kept independent of `App` so the state transition and the lifetime of a
/// committed payload can be proved without constructing a window, renderer or
/// PTY. The app calls this before its ordinary event switch and stages a
/// `.committed` payload in the same iteration, while SDL still owns it.
fn routeInputMethodEvent(composition: *inputmod.Composition, event: platform.Event) InputMethodOutcome {
    return switch (event) {
        .text_editing => |editing| changed: {
            composition.update(editing);
            break :changed .preedit;
        },
        .candidates => |candidates| changed: {
            composition.setCandidates(candidates);
            break :changed .candidates;
        },
        .text_input => |committed| .{ .committed = composition.commit(committed) },
        else => .unrelated,
    };
}

/// Translate one key against the app's live input-method state.
fn translateAppKey(
    composition: *const inputmod.Composition,
    scratch: *inputmod.TextScratch,
    key: platform.KeyEvent,
) inputmod.Press {
    return inputmod.translate(scratch, key, composition.isComposing());
}

/// Append one event's bytes to the fixed child-input staging value.
///
/// False means the whole event was refused: keeping the prefix would turn
/// valid UTF-8 or an escape sequence into malformed input. The caller logs
/// only byte counts, never the user's text.
fn appendChildInput(staged: *term.EncodedKey, bytes: []const u8) bool {
    if (bytes.len == 0) return true;
    const free = staged.bytes.len - staged.len;
    if (bytes.len > free) return false;
    @memcpy(staged.bytes[staged.len..][0..bytes.len], bytes);
    staged.len += bytes.len;
    return true;
}

/// Hold one committed-text payload until the event handler reaches the app's
/// single child-write site. The slice is borrowed from the platform event and
/// therefore must be taken before another event is pumped.
fn queueCommittedText(pending: *[]const u8, text: []const u8) void {
    // Every handled event flushes before the next pump. A non-empty value here
    // would mean a caller broke that lifetime contract.
    std.debug.assert(pending.*.len == 0);
    pending.* = text;
}

/// Take and clear the borrowed committed-text payload in one operation.
fn takeCommittedText(pending: *[]const u8) []const u8 {
    const text = pending.*;
    pending.* = "";
    return text;
}

/// Convert a device-pixel cell extent to the logical pixels SDL expects for
/// text-input placement.
fn logicalPixels(physical: u32, scale: platform.Scale) u32 {
    const value = @round(
        @as(f64, @floatFromInt(physical)) /
            @as(f64, @floatCast(scale.factor)),
    );
    if (value >= @as(f64, @floatFromInt(std.math.maxInt(u32)))) return std.math.maxInt(u32);
    return @max(1, @as(u32, @intFromFloat(value)));
}

const ui_test_initial_origin = ui.Rect{ .x = 4, .y = 2, .width = 0, .height = 0 };
const ui_test_moved_origin = ui.Rect{ .x = 34, .y = 2, .width = 0, .height = 0 };
const ui_test_surface_width: u32 = 24;
const ui_test_surface_height: u32 = 9;
const ui_test_min_cols: u32 = ui_test_moved_origin.x + ui_test_surface_width;
const ui_test_min_rows: u32 = ui_test_initial_origin.y + ui_test_surface_height + 1;
const ui_test_terminal_background = render.Rgba{ .r = 17, .g = 31, .b = 47 };
const ui_test_terminal_damage = render.Rgba{ .r = 41, .g = 73, .b = 59 };

/// The state owned by `uiTest` while its borrowed pointer is attached to App.
/// No production UI state or routing is introduced by this fixture.
const UiTestFixture = struct {
    tree: ui.Tree,
    canvas: ui.Canvas,
    field: ui.Input,
    origin: ui.Rect = ui_test_initial_origin,
    last_dispatch: ?UiTestDispatch = null,
    dispatch_count: usize = 0,

    fn init(allocator: Allocator, size: term.GridSize) !UiTestFixture {
        var tree = try ui.Tree.init(allocator, 6, 4);
        errdefer tree.deinit();
        var canvas = try ui.Canvas.init(allocator, size.cols, size.rows);
        errdefer canvas.deinit();
        var field = try ui.Input.init(allocator, 32, "seed");
        field.selectAll();
        return .{ .tree = tree, .canvas = canvas, .field = field };
    }

    fn deinit(self: *UiTestFixture) void {
        self.field.deinit();
        self.canvas.deinit();
        self.tree.deinit();
        self.* = undefined;
    }

    fn surfaceRect(self: *const UiTestFixture) ui.Rect {
        return .{
            .x = self.origin.x,
            .y = self.origin.y,
            .width = ui_test_surface_width,
            .height = ui_test_surface_height,
        };
    }

    fn textRect(self: *const UiTestFixture) ui.Rect {
        return .{ .x = self.origin.x + 3, .y = self.origin.y + 2, .width = 10, .height = 1 };
    }

    fn interactiveRect(self: *const UiTestFixture) ui.Rect {
        return .{ .x = self.origin.x + 3, .y = self.origin.y + 4, .width = 10, .height = 1 };
    }

    fn inputRect(self: *const UiTestFixture) ui.Rect {
        return .{ .x = self.origin.x + 3, .y = self.origin.y + 6, .width = 10, .height = 1 };
    }

    fn overlappingRect(self: *const UiTestFixture) ui.Rect {
        return .{ .x = self.origin.x + 14, .y = self.origin.y + 3, .width = 8, .height = 4 };
    }

    fn transparentPosition(self: *const UiTestFixture) render.OverlayPosition {
        return .{ .col = self.origin.x - 2, .row = self.origin.y + 1 };
    }

    fn baseSample(self: *const UiTestFixture) render.OverlayPosition {
        return .{ .col = self.origin.x + 10, .row = self.origin.y + 7 };
    }

    fn overlapSample(self: *const UiTestFixture) render.OverlayPosition {
        return .{ .col = self.origin.x + 16, .row = self.origin.y + 4 };
    }

    /// Rebuild the sole semantic frame and derive the canvas from it without
    /// allocating. Stable ids preserve focus and presses across every rebuild.
    fn compose(self: *UiTestFixture, geometry: ui.Geometry) !void {
        try self.tree.beginFrame(geometry);
        const surface_id = ui.Id{ .value = "ui-test.surface" };
        try self.tree.addSurface(.{
            .id = surface_id,
            .role = "surface",
            .label = "UI test surface",
            .bounds = self.surfaceRect(),
        }, .{
            .rect = ui.Rect.empty,
            .fill = .blue,
            .border = .single,
            .border_style = .{ .foreground = .bright_white },
            .title = " UI ",
            .title_style = .{ .foreground = .bright_yellow, .face_style = .bold },
        });

        const styled_runs = [_]ui.Run{.{
            .text = "Styled",
            .style = .{ .foreground = .bright_white, .face_style = .bold_italic },
        }};
        try self.tree.addText(.{
            .id = .{ .value = "ui-test.styled" },
            .parent = surface_id,
            .role = "text",
            .label = "Styled",
            .bounds = self.textRect(),
        }, .{ .runs = &styled_runs });

        try self.tree.addInteractiveText(.{
            .id = .{ .value = "ui-test.action" },
            .parent = surface_id,
            .role = "action",
            .label = "Action",
            .action = "ui-test.activate",
            .bounds = self.interactiveRect(),
        }, .{
            .id = .{ .value = "ui-test.action" },
            .label = "Action",
            .action = "ui-test.activate",
            .normal = .{ .foreground = .bright_white },
            .hovered = .{
                .foreground = .bright_yellow,
                .face_style = .italic,
                .underline = .accent,
            },
            .focused = .{
                .foreground = .black,
                .background = .accent,
                .face_style = .bold,
            },
        });

        try self.tree.addInput(.{
            .id = .{ .value = "ui-test.input" },
            .parent = surface_id,
            .role = "input",
            .label = "Input",
            .bounds = self.inputRect(),
        }, &self.field, .{
            .text = .{ .foreground = .foreground, .background = .black },
            .selection_background = .selection,
            .cursor_background = .accent,
            .cursor_foreground = .background,
        });

        try self.tree.addSurface(.{
            .id = .{ .value = "ui-test.overlap" },
            .parent = surface_id,
            .role = "surface",
            .label = "Overlap",
            .bounds = self.overlappingRect(),
        }, .{
            .rect = ui.Rect.empty,
            .fill = .red,
        });

        const transparent_runs = [_]ui.Run{.{
            .text = " ",
            .style = .{ .foreground = .foreground },
        }};
        const transparent = self.transparentPosition();
        try self.tree.addText(.{
            .id = .{ .value = "ui-test.transparent" },
            .role = "text",
            .label = "Transparent",
            .bounds = .{
                .x = transparent.col,
                .y = transparent.row,
                .width = 1,
                .height = 1,
            },
        }, .{ .runs = &transparent_runs });
        try self.tree.endFrame();
        try self.tree.render(&self.canvas);
    }

    fn remove(self: *UiTestFixture, geometry: ui.Geometry) !void {
        try self.tree.beginFrame(geometry);
        try self.tree.endFrame();
        try self.tree.render(&self.canvas);
    }

    fn rerender(self: *UiTestFixture) !void {
        try self.tree.render(&self.canvas);
    }

    fn recordDispatch(self: *UiTestFixture, invocation: inputmod.Invocation) void {
        self.last_dispatch = .{
            .source = invocation.source,
            .origin = invocation.origin,
            .action = "ui-test.activate",
        };
        self.dispatch_count += 1;
    }

    fn view(self: *UiTestFixture) render.OverlayView {
        return self.canvas.view(&default_palette);
    }
};

const UiTestDispatch = struct {
    source: inputmod.InvocationSource,
    origin: ?ui.Id,
    action: []const u8,
};

const UiInteractionState = struct {
    hovered: ?usize = null,
    focused: ?usize = null,
    pressed: ?usize = null,
};

const TerminalInputDebt = struct {
    encoded: usize = 0,
    staged: usize = 0,
    committed: usize = 0,
    paste: bool = false,
    responses: usize = 0,

    fn remains(self: TerminalInputDebt) bool {
        return self.encoded != 0 or self.staged != 0 or self.committed != 0 or
            self.paste or self.responses != 0;
    }
};

const ui_key_capacity: usize = 16;

const UiKeyIdentity = union(enum) {
    named: platform.Key,
    character: u21,
};

fn uiKeyIdentity(raw: platform.KeyEvent) ?UiKeyIdentity {
    if (raw.key != .unidentified) return .{ .named = raw.key };
    if (raw.unshifted_codepoint == 0) return null;
    return .{ .character = raw.unshifted_codepoint };
}

fn uiKeyIdentityEql(a: UiKeyIdentity, b: UiKeyIdentity) bool {
    return switch (a) {
        .named => |a_named| switch (b) {
            .named => |b_named| a_named == b_named,
            .character => false,
        },
        .character => |a_character| switch (b) {
            .named => false,
            .character => |b_character| a_character == b_character,
        },
    };
}

const UiKeyText = struct {
    bytes: [4]u8 = undefined,
    len: u3 = 0,

    fn copy(text: []const u8) UiKeyText {
        std.debug.assert(text.len <= 4);
        var copied: UiKeyText = .{ .len = @intCast(text.len) };
        @memcpy(copied.bytes[0..text.len], text);
        return copied;
    }

    fn slice(self: *const UiKeyText) []const u8 {
        return self.bytes[0..self.len];
    }
};

const UiInputEdit = enum {
    previous,
    next,
    home,
    end,
    backspace,
    delete,
};

const UiTextOperation = struct { origin: ui.Id, value: UiKeyText };
const UiEditOperation = struct { origin: ui.Id, operation: UiInputEdit, extend: bool };

const UiKeyRepeat = union(enum) {
    none,
    text: UiTextOperation,
    edit: UiEditOperation,
};

const UiOwnedKey = struct {
    identity: UiKeyIdentity,
    repeat: UiKeyRepeat,
};

fn searchKeyAction(
    profile: inputmod.PlatformProfile,
    visible: bool,
    key: platform.KeyEvent,
) ?[]const u8 {
    const letter = std.ascii.toLower(@as(u8, @intCast(@min(key.unshifted_codepoint, 0xff))));
    const open = switch (profile) {
        .macos => letter == 'f' and key.mods.super and !key.mods.ctrl and !key.mods.alt and !key.mods.shift,
        .linux_windows => letter == 'f' and key.mods.ctrl and key.mods.shift and !key.mods.alt and !key.mods.super,
    };
    if (!visible) return if (open) search_open_action else null;
    if (open) return search_open_action;
    if (key.key == .escape and !key.mods.ctrl and !key.mods.alt and !key.mods.shift and !key.mods.super) {
        return search_close_action;
    }
    if ((key.key == .enter or key.key == .f3) and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
        return if (key.mods.shift) search_previous_action else search_next_action;
    }
    if (key.mods.alt and !key.mods.ctrl and !key.mods.shift and !key.mods.super) {
        if (letter == 'c') return search_case_action;
        if (letter == 'r') return search_regex_action;
    }
    return null;
}

fn nextSearchIndex(current: usize, count: usize, next: bool) usize {
    if (count == 0) return 0;
    const bounded = @min(current, count - 1);
    if (next) return (bounded + 1) % count;
    return if (bounded == 0) count - 1 else bounded - 1;
}

fn searchWorkPending(
    visible: bool,
    engine_live: bool,
    needs_sync: bool,
    progress: term.SearchProgress,
    has_page_scan: bool,
) bool {
    return visible and engine_live and
        (needs_sync or searchVisibleProgress(progress, has_page_scan) == .running);
}

/// Engine progress covers literal history preparation. Page materialization
/// is separate work (and all regex work), so it remains user-visible as a
/// running search until its cursor reaches a real boundary.
fn searchVisibleProgress(progress: term.SearchProgress, has_page_scan: bool) term.SearchProgress {
    return if (has_page_scan) .running else progress;
}

fn searchFailureText(err: anyerror) []const u8 {
    return switch (err) {
        error.InvalidRegex => "invalid regex",
        error.RegexTooComplex => "regex too complex",
        error.RegexWorkLimit => "regex work limit",
        else => @errorName(err),
    };
}

/// Inline transition ownership survives App's return-by-value move without a
/// self-referential slice. Identity deliberately excludes modifiers: releasing
/// them before the target key cannot change who owns that target's release.
const UiKeyState = struct {
    storage: [ui_key_capacity]UiOwnedKey = undefined,
    len: usize = 0,

    fn indexOf(self: *const UiKeyState, identity: UiKeyIdentity) ?usize {
        for (self.storage[0..self.len], 0..) |owned, index| {
            if (uiKeyIdentityEql(owned.identity, identity)) return index;
        }
        return null;
    }

    fn claim(self: *UiKeyState, identity: UiKeyIdentity, repeat: UiKeyRepeat) bool {
        if (self.indexOf(identity) != null or self.len == self.storage.len) return false;
        self.storage[self.len] = .{ .identity = identity, .repeat = repeat };
        self.len += 1;
        return true;
    }

    fn release(self: *UiKeyState, index: usize) void {
        var destination = index;
        while (destination + 1 < self.len) : (destination += 1) {
            self.storage[destination] = self.storage[destination + 1];
        }
        self.len -= 1;
    }
};

/// One row of the terminal context menu: a stable semantic id, its terse label
/// and the completed named action the row dispatches. All strings are
/// comptime constants, so a composed row borrows nothing that can move.
const ContextMenuItem = struct {
    id: []const u8,
    label: []const u8,
    action: []const u8,
};

const context_menu_copy_item: ContextMenuItem = .{ .id = "context-menu.copy", .label = "copy", .action = clipboard_copy_action };
const context_menu_paste_item: ContextMenuItem = .{ .id = "context-menu.paste", .label = "paste", .action = clipboard_paste_action };
const context_menu_open_link_item: ContextMenuItem = .{ .id = "context-menu.open-link", .label = "open link", .action = terminal_open_link_action };
const context_menu_split_right_item: ContextMenuItem = .{ .id = "context-menu.split-right", .label = "split right", .action = pane_split_action };
const context_menu_split_down_item: ContextMenuItem = .{ .id = "context-menu.split-down", .label = "split down", .action = pane_split_action };
const context_menu_search_item: ContextMenuItem = .{ .id = "context-menu.search", .label = "search", .action = search_open_action };

/// Every row the menu can show; the composed list is a subset in this order.
const context_menu_max_items: usize = 6;
/// Border, one cell of padding each side and the widest label (`split right`).
const context_menu_width: u32 = 15;

/// The rows the menu shows for one gesture. `copy` needs something to copy and
/// `open link` needs a link under the pointer; the rest always apply to a
/// terminal pane. Pure so the rule is unit-testable without a window.
fn contextMenuItems(
    has_selection: bool,
    has_link: bool,
    storage: *[context_menu_max_items]ContextMenuItem,
) []const ContextMenuItem {
    var count: usize = 0;
    if (has_selection) {
        storage[count] = context_menu_copy_item;
        count += 1;
    }
    storage[count] = context_menu_paste_item;
    count += 1;
    if (has_link) {
        storage[count] = context_menu_open_link_item;
        count += 1;
    }
    storage[count] = context_menu_split_right_item;
    count += 1;
    storage[count] = context_menu_split_down_item;
    count += 1;
    storage[count] = context_menu_search_item;
    count += 1;
    return storage[0..count];
}

/// Where the menu panel sits: its top-left corner on the anchor cell, moved
/// left or up only as far as needed to keep every row inside the canvas. A
/// canvas too small for the whole panel gets no menu rather than a clipped one.
fn contextMenuBounds(anchor_col: u32, anchor_row: u32, item_count: usize, canvas: ui.Rect) ?ui.Rect {
    const height: u32 = @as(u32, @intCast(item_count)) + 2;
    if (canvas.width < context_menu_width or canvas.height < height) return null;
    return .{
        .x = @min(anchor_col, canvas.width - context_menu_width),
        .y = @min(anchor_row, canvas.height - height),
        .width = context_menu_width,
        .height = height,
    };
}

/// The open context menu. Everything a row needs at activation is copied here
/// when the menu opens, because the semantic tree it was read from is rebuilt
/// before any row runs.
const ContextMenu = struct {
    /// The canvas cell the panel is anchored to before clamping.
    col: u32,
    row: u32,
    /// Whether the presented terminal had a selection when the menu opened.
    has_selection: bool,
    /// The stable id of the terminal link under the pointer, if any.
    link_id_len: usize = 0,
    link_id: [terminal_link_semantic_capacity]u8 = undefined,

    fn linkId(self: *const ContextMenu) ?[]const u8 {
        return if (self.link_id_len == 0) null else self.link_id[0..self.link_id_len];
    }
};

const UiKeyPlan = union(enum) {
    consume,
    focus: bool,
    focus_id: ui.Id,
    workspace_focus: bool,
    activate: ui.Activation,
    palette_close,
    palette_move: bool,
    palette_activate,
    context_menu_close,
    context_menu_move: bool,
    context_menu_activate,
    select_all: ui.Id,
    copy: ui.Id,
    paste: ui.Id,
    text: UiTextOperation,
    edit: UiEditOperation,

    fn repeat(self: UiKeyPlan) UiKeyRepeat {
        return switch (self) {
            .text => |text| .{ .text = text },
            .edit => |edit| .{ .edit = edit },
            else => .none,
        };
    }
};

fn uiInteractionState(tree: *const ui.Tree) UiInteractionState {
    var state: UiInteractionState = .{};
    for (tree.elements(), 0..) |element, index| {
        if (element.state.hovered) state.hovered = index;
        if (element.state.focused) state.focused = index;
        if (element.state.pressed) state.pressed = index;
    }
    return state;
}

fn devicePointerPoint(x: f32, y: f32, scale: platform.Scale) ui.Point {
    return .{
        .x = devicePointerCoordinate(x, scale),
        .y = devicePointerCoordinate(y, scale),
    };
}

fn devicePointerCoordinate(logical: f32, scale: platform.Scale) i32 {
    if (!std.math.isFinite(logical)) return 0;
    const device = @as(f64, @floatCast(logical)) * @as(f64, scale.factor);
    if (!std.math.isFinite(device)) return if (device < 0) std.math.minInt(i32) else std.math.maxInt(i32);
    const rounded = @floor(device);
    if (rounded <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (rounded >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(rounded);
}

/// Cell width of a valid UTF-8 preedit prefix. This mirrors Text's grapheme
/// measurement without allocating, so the native candidate window can follow
/// the caret that the inline renderer actually draws.
fn preeditCellWidth(text: []const u8) ?u32 {
    const view = std.unicode.Utf8View.init(text) catch return null;
    var codepoints: [inputmod.Composition.max_preedit]u21 = undefined;
    var count: usize = 0;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0)) continue;
        codepoints[count] = codepoint;
        count += 1;
    }

    var width: u32 = 0;
    var index: usize = 0;
    while (index < count) {
        const measured = term.graphemeWidth(codepoints[index..count]);
        width +|= measured.width;
        index += @max(measured.len, 1);
    }
    return width;
}

fn utf8Boundary(text: []const u8, offset: usize) bool {
    if (offset > text.len) return false;
    return std.unicode.utf8ValidateSlice(text[0..offset]);
}

fn privateArtifactPermissions(comptime directory: bool) File.Permissions {
    if (comptime builtin.os.tag == .windows) {
        return if (directory) .default_dir else .default_file;
    } else {
        return .fromMode(if (directory) 0o700 else 0o600);
    }
}

/// One PNG artifact encoded and persisted away from the render thread.
///
/// The main thread owns the OpenGL readback and hands this job an independent
/// pixel copy. The worker owns PNG compression and filesystem IO, then wakes
/// SDL so the driver response can be completed on the main thread.
const ScreenshotJob = struct {
    allocator: Allocator,
    io: Io,
    window: ?*platform.Window,
    path: []u8,
    pixels: []u8,
    size: render.Size,
    state: std.atomic.Value(u32) = .init(0),
    failure: ?[]const u8 = null,
    thread: ?std.Thread = null,

    fn start(self: *ScreenshotJob) !void {
        self.thread = try std.Thread.spawn(.{}, work, .{self});
    }

    fn finished(self: *const ScreenshotJob) bool {
        return self.state.load(.acquire) != 0;
    }

    fn work(self: *ScreenshotJob) void {
        self.write() catch |err| {
            self.failure = @errorName(err);
        };
        self.state.store(1, .release);
        if (self.window) |window| window.postDriverWake() catch |err| {
            log.warn("screenshot worker could not wake the event loop: {s}", .{@errorName(err)});
        };
    }

    fn write(self: *ScreenshotJob) !void {
        const encoded = try render.encodePng(self.allocator, self.size, self.pixels);
        defer self.allocator.free(encoded);

        const parent = std.fs.path.dirname(self.path) orelse ".";
        _ = try Dir.cwd().createDirPathStatus(self.io, parent, privateArtifactPermissions(true));
        var file = try Dir.cwd().createFile(self.io, self.path, .{
            .exclusive = true,
            .permissions = privateArtifactPermissions(false),
        });
        var complete = false;
        defer {
            file.close(self.io);
            if (!complete) Dir.cwd().deleteFile(self.io, self.path) catch |err| {
                log.warn("could not remove an incomplete screenshot: {s}", .{@errorName(err)});
            };
        }
        var buffer: [4096]u8 = undefined;
        var streaming = file.writerStreaming(self.io, &buffer);
        try streaming.interface.writeAll(encoded);
        try streaming.interface.flush();
        complete = true;
    }

    fn deinit(self: *ScreenshotJob) void {
        if (self.thread) |thread| thread.join();
        self.allocator.free(self.pixels);
        self.allocator.free(self.path);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

const DriverPendingState = union(enum) {
    barrier: struct {
        id: u32,
        posted: bool,
    },
    wait: i128,
    screenshot: *ScreenshotJob,
};

/// One parsed driver request retained across event-loop turns.
///
/// Input requests retain their arena through the SDL barrier because a posted
/// text-input event borrows its UTF-8 bytes. Wait requests retain their
/// condition strings through their deadline.
const DriverPending = struct {
    token: u64,
    parsed: testdriver.ParsedRequest,
    state: DriverPendingState,
    text: ?[:0]u8 = null,

    fn deinit(self: *DriverPending, allocator: Allocator) void {
        if (self.text) |text| allocator.free(text);
        switch (self.state) {
            .screenshot => |job| job.deinit(),
            else => {},
        }
        self.parsed.deinit();
        self.* = undefined;
    }
};

const driver_pending_capacity = platform.max_driver_pending;

const PaneRenderer = struct {
    session_id: session.SessionId,
    grid: render.Grid,

    fn deinit(self: *PaneRenderer) void {
        self.grid.deinit();
        self.* = undefined;
    }
};

/// App-owned rendering and asynchronous presentation state for one
/// registry-owned workspace. The registry keeps the `Workspace` itself at a
/// stable heap address; this parallel record is also heap-stable so a worker
/// result can remain attributed to its originating workspace while selection
/// changes.
const WorkspacePresentation = struct {
    key: workspace.WorkspaceKey,
    active_session_id: session.SessionId,
    pane_renderers: std.ArrayList(PaneRenderer),
    scratchpad_grid: render.Grid,
    scratchpad_presentation: ScratchpadPresentation = .hidden,
    load: ?*Load = null,
    scratchpad_load: ?*Load = null,
    closing: bool = false,
};

const WorkspaceEventContext = struct {
    app: *App,
    key: workspace.WorkspaceKey,
};

const PendingPaneClose = struct {
    tab_id: workspace.TabId,
    pane_id: workspace.PaneId,
};

const WorkspaceSemanticTarget = struct {
    key: workspace.WorkspaceKey,
    ordinal: u32,
};

const pane_semantic_capacity = workspace_semantic_capacity;

const UrlOpener = struct {
    context: ?*anyopaque = null,
    open_fn: *const fn (?*anyopaque, Allocator, []const u8) anyerror!void = openSystemUrl,

    fn open(self: UrlOpener, allocator: Allocator, url: []const u8) !void {
        try self.open_fn(self.context, allocator, url);
    }
};

fn openSystemUrl(_: ?*anyopaque, allocator: Allocator, url: []const u8) !void {
    try platform.openUrl(allocator, url);
}

const TerminalLinkTarget = struct {
    id: []const u8,
    kind: TerminalLinkTargetKind,
    /// The exact URL for `.url`, or the visible path spelling for `.file`.
    /// Borrows `App.terminal_link_text` until the next UI composition.
    target: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    session_id: session.SessionId,
};

/// Sees the exact editor spawn a file reference produced before its worker
/// starts. Deterministic checks record argv and cwd here; the real spawn
/// through the workspace `ExecutionContext` proceeds regardless.
const EditorSpawnObserver = struct {
    context: ?*anyopaque = null,
    observe_fn: ?*const fn (?*anyopaque, []const []const u8, []const u8) void = null,

    fn observe(self: EditorSpawnObserver, argv: []const []const u8, cwd: []const u8) void {
        const observe_fn = self.observe_fn orelse return;
        observe_fn(self.context, argv, cwd);
    }
};

/// The built-in v0.1 editor for file references (decision-5). v0.1 has no
/// config file, so the "configured editor command" is this default. It is
/// always spawned as shell-free argv `vi +<line> -- <path>`; a detected column
/// is kept for identity but never passed.
const file_reference_editor = "vi";
/// A tab label is the referenced file name, cut on a codepoint boundary.
const file_reference_label_max_bytes: usize = 64;
/// Longest resolved path handed to the editor. The workspace may be remote,
/// so this bounds hostile terminal text rather than mirroring a local limit.
const file_reference_path_max_bytes: usize = 4096;

const FileReferenceArgvError = error{ UnsafePath, PathTooLong, OutOfMemory };

/// Whether a detected path spelling stands on its own rather than relative to
/// the session cwd. Nothing here touches the filesystem.
fn fileReferenceIsAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 2 and path[1] == ':' and std.ascii.isAlphabetic(path[0]);
}

/// Argv text must be non-empty, valid UTF-8 and free of C0/C1 controls. The
/// detector already rejects these, but the spawn boundary re-checks them
/// because that is where terminal-derived text becomes a process argument.
fn fileReferenceTextIsSafe(text: []const u8) bool {
    if (text.len == 0) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0) or
            codepoint == 0x2028 or codepoint == 0x2029) return false;
    }
    return true;
}

/// Build the owned argv `vi +<line> -- <path>` (or `vi -- <path>`) for one
/// detected file reference. A relative spelling is joined to `cwd` after
/// dropping leading `./` segments; nothing is canonicalized, stat'ed or read.
/// Ownership of the returned entries and slice transfers to the caller, who
/// releases them with `freeEntries`.
fn buildFileReferenceArgv(
    allocator: Allocator,
    path: []const u8,
    line: ?u32,
    cwd: []const u8,
) FileReferenceArgvError![][]const u8 {
    if (!fileReferenceTextIsSafe(path)) return error.UnsafePath;
    const absolute = fileReferenceIsAbsolute(path);
    var spelled = path;
    if (!absolute) {
        if (!fileReferenceTextIsSafe(cwd)) return error.UnsafePath;
        while (std.mem.startsWith(u8, spelled, "./")) spelled = spelled[2..];
        if (spelled.len == 0) return error.UnsafePath;
    }
    const separator: []const u8 = if (absolute or cwd[cwd.len - 1] == '/') "" else "/";
    const resolved_len = if (absolute) spelled.len else cwd.len + separator.len + spelled.len;
    if (resolved_len > file_reference_path_max_bytes) return error.PathTooLong;

    const count: usize = if (line != null) 4 else 3;
    const argv = try allocator.alloc([]const u8, count);
    var filled: usize = 0;
    errdefer {
        for (argv[0..filled]) |entry| allocator.free(entry);
        allocator.free(argv);
    }
    argv[filled] = try allocator.dupe(u8, file_reference_editor);
    filled += 1;
    if (line) |value| {
        argv[filled] = try std.fmt.allocPrint(allocator, "+{d}", .{value});
        filled += 1;
    }
    argv[filled] = try allocator.dupe(u8, "--");
    filled += 1;
    argv[filled] = if (absolute)
        try allocator.dupe(u8, spelled)
    else
        try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ cwd, separator, spelled });
    filled += 1;
    return argv;
}

/// The tab label for a file reference: its final path component, bounded on a
/// codepoint boundary. Borrows `path`.
fn fileReferenceLabel(path: []const u8) []const u8 {
    var name = path;
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |index| name = path[index + 1 ..];
    if (name.len == 0) name = path;
    if (name.len <= file_reference_label_max_bytes) return name;
    var end = file_reference_label_max_bytes;
    while (end > 0 and name[end] & 0xc0 == 0x80) : (end -= 1) {}
    return name[0..end];
}

const TerminalLinkTargetKind = enum(u8) {
    url = 1,
    file = 2,
};

const terminal_link_fingerprint_bytes = 16;

/// Produce a collision-resistant stable identity for an untrusted terminal
/// target. Zero encodes an absent source location because parsed line and
/// column values are one-based; fixed-width fields keep every input tuple
/// unambiguous without copying the target.
fn terminalLinkFingerprint(
    kind: TerminalLinkTargetKind,
    target: []const u8,
    line: ?u32,
    column: ?u32,
) [terminal_link_fingerprint_bytes]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("conduit-terminal-link-v1\x00");
    const kind_bytes = [1]u8{@intFromEnum(kind)};
    hash.update(&kind_bytes);
    var line_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &line_bytes, line orelse 0, .big);
    hash.update(&line_bytes);
    var column_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &column_bytes, column orelse 0, .big);
    hash.update(&column_bytes);
    hash.update(target);

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&digest);
    var fingerprint: [terminal_link_fingerprint_bytes]u8 = undefined;
    @memcpy(fingerprint[0..], digest[0..fingerprint.len]);
    return fingerprint;
}

const TerminalLinkCellBounds = struct {
    col: u16,
    width: u16,
};

/// Everything one run of Conduit owns: the surface it draws into, the live
/// session behind that surface, and what should happen next.
///
/// Ownership: `init` allocates the App itself with `allocator`; its caller owns
/// the returned stable pointer and releases it with `destroy`. `allocator` is
/// otherwise borrowed from `main` and every allocation the app makes comes
/// from it. `readback`, `input` and `output` are the app's; `spec` owns the
/// strings children are started with; the app and its workspace presentation
/// records own worker jobs until they are collected. The window is borrowed
/// and destroyed after `destroy`, because a window outlives every frame and
/// dies before the process.
const App = struct {
    allocator: Allocator,
    io: Io,
    window: *platform.Window,
    surface: render.Surface,
    /// The size the surface is currently at, so a window state that implies the
    /// size already in use costs nothing.
    size: render.Size,
    /// The readback buffer, allocated once at the largest surface seen and
    /// reused by every capture.
    readback: []u8,
    /// What a full frame is cleared to, kept beside the surface because the
    /// capture report counts pixels of exactly this colour.
    background: render.Rgba,
    /// Set when what is on the window's framebuffer may not match the surface:
    /// a resize, a scale change and an expose all leave the two out of step.
    needs_present: bool,
    scheduler: Scheduler,
    /// The face the grid is rasterised from. Owned.
    fonts: font.Manager,
    /// Registry-owned workspace models and their parallel, heap-stable
    /// presentation records. Both collections use the same stable keys.
    workspace_registry: workspace.WorkspaceRegistry,
    workspace_presentations: std.ArrayList(*WorkspacePresentation),
    /// The overlay has its own renderer state because it spans the full canvas
    /// and is composited only after every visible pane.
    overlay_grid: render.Grid,
    pane_layouts: []workspace.PaneLayout,
    pane_layout_count: usize = 0,
    divider_layouts: []workspace.DividerLayout,
    divider_layout_count: usize = 0,
    workspace_semantic_storage: [sidebar_element_capacity][workspace_semantic_capacity]u8 = undefined,
    tab_semantic_storage: [sidebar_element_capacity][workspace_semantic_capacity]u8 = undefined,
    tab_rename_semantic_storage: [workspace_semantic_capacity]u8 = undefined,
    pane_semantic_storage: [sidebar_element_capacity][pane_semantic_capacity]u8 = undefined,
    divider_semantic_storage: [sidebar_element_capacity][pane_semantic_capacity]u8 = undefined,
    divider_visual_storage: [sidebar_element_capacity][pane_semantic_capacity + 7]u8 = undefined,
    scratchpad_semantic_storage: [4][workspace_semantic_capacity]u8 = undefined,
    terminal_link_ids: [2][terminal_link_capacity][terminal_link_semantic_capacity]u8 = undefined,
    terminal_link_id_generation: usize = 0,
    terminal_link_targets: [terminal_link_capacity]TerminalLinkTarget = undefined,
    terminal_link_target_count: usize = 0,
    terminal_link_text: [terminal_link_frame_bytes]u8 = undefined,
    terminal_link_text_len: usize = 0,
    terminal_link_row: [terminal_link_row_bytes]u8 = undefined,
    terminal_link_ranges: [terminal_link_osc_capacity]link.Osc8Range = undefined,
    terminal_link_matches: [terminal_link_capacity]link.Match = undefined,
    terminal_link_modifier: bool = false,
    url_opener: UrlOpener = .{},
    editor_spawn_observer: EditorSpawnObserver = .{},
    /// What the child was started with.
    spec: ChildSpec,
    /// The scratchpad's independent interactive shell specification. It never
    /// contains a run's command or deterministic test peer.
    scratchpad_spec: ChildSpec,
    /// Bytes copied out of the child each frame.
    input: []u8,
    /// Answers the terminal owes the child.
    output: []u8,
    /// Bytes an input event produced for the child, waiting to go out with the
    /// terminal's own answers.
    ///
    /// A fixed value rather than a buffer: a key or a wheel report is a few
    /// dozen bytes at most, the count is fixed here so a frame allocates
    /// nothing, and `pumpChild` writes it from the same place it writes the
    /// terminal's answers — two writers to one child is how interleaved bytes
    /// arrive.
    child_input: term.EncodedKey,
    /// The input method's live preedit and candidate state. It belongs to the
    /// app because platform event payloads expire at the next event, while the
    /// renderer will eventually need the preedit for a later frame.
    composition: inputmod.Composition,
    /// The production UI layer. It is allocated and resized with the terminal
    /// grid, then reused by every frame; composing a preedit allocates nothing.
    ui_canvas: ui.Canvas,
    /// The semantic source of the production UI canvas. One fixed-capacity
    /// tree frame is rebuilt before each draw; Canvas is only its projection.
    ui_tree: ui.Tree,
    /// Registry borrows this allocator-stable storage. Keeping it off the App
    /// value avoids leaving a slice pointed into the pre-return stack copy.
    action_definitions: []inputmod.ActionDefinition,
    actions: inputmod.Registry,
    palette_model: palette_mod.Model,
    palette_query: ui.Input,
    palette_argument: ui.Input,
    palette_step: PaletteStep = .closed,
    palette_pointer_owned: bool = false,
    /// The `mouse.right_click` setting resolved through `config.Layer` at
    /// startup: the built-in `menu` unless `--right-click=` supplied a
    /// session value. Owned by the main thread with every other UI state.
    right_click: config.RightClick = config.RightClick.built_in,
    /// The open terminal context menu, or null. Composed into `ui_tree` each
    /// frame while open; it is modal for pointer and key input like the palette.
    context_menu: ?ContextMenu = null,
    /// A pointer gesture the right-click machinery consumed (a menu-opening or
    /// pasting right press, a menu row press, or a closing outside press) owns
    /// its motion and release so no tail reaches the terminal beneath.
    context_menu_pointer_owned: bool = false,
    palette_row_ids: [palette_action_capacity][palette_semantic_capacity]u8 = undefined,
    palette_row_labels: [palette_action_capacity][palette_label_capacity]u8 = undefined,
    palette_choice_ids: [palette_action_capacity][palette_action_capacity][palette_semantic_capacity]u8 = undefined,
    search_query: ui.Input,
    search_visible: bool = false,
    search_case: term.SearchCase = .ascii_insensitive,
    search_mode: SearchMode = .literal,
    search_engine: term.ScrollbackSearch = undefined,
    search_engine_live: bool = false,
    search_session_id: ?session.SessionId = null,
    search_scratch: [search_scratch_capacity]u8 = undefined,
    search_pages: [2][search_match_capacity]term.LocatedSearchMatch = undefined,
    search_page_slot: usize = 0,
    search_page_scan: ?SearchPageScan = null,
    search_match_count: usize = 0,
    search_active_index: usize = 0,
    search_progress: term.SearchProgress = .complete,
    search_truncated: bool = false,
    search_needs_sync: bool = false,
    search_restart_on_sync: bool = false,
    search_follow_pending: bool = false,
    search_failure: ?[]const u8 = null,
    /// Diagnostic counter used by the deterministic search check to prove
    /// that real PTY output crossed the generation-resync path.
    search_resync_count: usize = 0,
    search_pointer_owned: bool = false,
    // Alternate identity storage each frame so Tree can reconcile the prior
    // frame without observing ids being reformatted underneath it.
    search_highlight_ids: [2][search_highlight_capacity][search_semantic_capacity]u8 = undefined,
    search_highlight_id_generation: usize = 0,
    search_control_label: [128]u8 = undefined,
    binding_profile: inputmod.PlatformProfile,
    bindings: []const inputmod.Binding,
    binding_keys: []inputmod.BindingKey,
    binding_state: inputmod.BindingState,
    ui_key_state: UiKeyState = .{},
    terminal_key_state: UiKeyState = .{},
    terminal_pointer_presses: usize = 0,
    ui_pointer_owned: bool = false,
    sidebar_enabled: bool,
    sidebar_visible: bool,
    sidebar_width_cols: u16 = sidebar_default_width,
    sidebar_dragging: bool = false,
    dragged_divider_id: ?workspace.DividerId = null,
    dragged_divider_split: ?workspace.PaneSplit = null,
    divider_drag_cell: i32 = 0,
    dragged_tab_id: ?workspace.TabId = null,
    rename_tab_id: ?workspace.TabId = null,
    rename_input: ?ui.Input = null,
    pending_close_tab_id: ?workspace.TabId = null,
    pending_close_pane: ?PendingPaneClose = null,
    pending_close_workspace: ?workspace.WorkspaceKey = null,
    workspace_status: ?[]const u8 = null,
    scratchpad_ui_pointer_owned: bool = false,
    scratchpad_terminal_pointer_owned: bool = false,
    scratchpad_escape_owned: bool = false,
    requested_shutdown: bool = false,
    action_dispatch_count: usize = 0,
    last_dispatched_action: ?[]const u8 = null,
    terminal_key_route_count: usize = 0,
    /// UTF-8 committed by the current platform event, borrowed until
    /// `flushToChild` consumes it in the same event-loop iteration. Empty
    /// means no committed text is pending.
    pending_committed_text: []const u8,
    /// Font discovery is app-global. Child and scratchpad spawn jobs live in
    /// their originating workspace presentation records.
    font_load: ?*Load,
    /// The family and display scale the current face was resolved at.
    family: []const u8,
    font_scale: f32,
    home_dir: ?[]const u8,
    /// The instant the blink phase is measured from.
    blink_epoch_ns: i128,
    blink_visible: bool,
    /// Leave the loop when the child does. `--command` is the one mode waiting
    /// for a program to finish rather than for a person to close a window.
    exit_with_child: bool,
    /// Whether a spawn has been attempted, so a run whose spawn failed ends
    /// rather than spinning until its deadline.
    spawn_finished: bool,
    /// Whether the child's exit has been logged, so that it is logged once.
    exit_logged: bool,
    /// Where `--screenshot` was asked to write, or null. Borrowed from the
    /// options, which live in the arena the whole run shares.
    ///
    /// Held because `--mouse-test` has to capture more than one frame: a word
    /// selection and a line selection cannot both be on the screen at once,
    /// and the run is what puts each of them there.
    screenshot: ?[]const u8 = null,

    /// Optional local automation transport. It exists only when the explicit
    /// endpoint flag was supplied, regardless of build mode.
    driver: ?*platform.DriverTransport = null,
    /// Run-scoped destination for screenshots requested through the driver.
    /// Borrowed from the run options and never exposed to terminal content.
    driver_artifact_dir: ?[]const u8 = null,
    next_screenshot_number: u32 = 1,
    driver_pending: [driver_pending_capacity]?DriverPending = @splat(null),
    next_driver_barrier: u32 = 1,
    driver_quit_deadline_ns: ?i128 = null,

    /// The `--ui-test` fixture while that check is running. Borrowed from the
    /// check's stack; null for every production frame.
    ui_test: ?*UiTestFixture = null,

    /// Where the pointer was when the OS last said so.
    ///
    /// Kept because autoscroll needs it and nothing else does: a drag that has
    /// reached past the edge of the window produces no further events, because
    /// the pointer is outside and not moving. The selection keeps growing only
    /// if something remembers where it left off.
    last_pointer: term.Pointer = .{},

    /// An encoded paste waiting for `pumpChild`, owned by `allocator`, or null.
    ///
    /// Not `child_input`: that is a fixed 256-byte value sized for one key or
    /// one mouse report, and a paste may be megabytes. It goes out from the
    /// same place every other byte for the child does, so there is still one
    /// write site.
    pending_paste: ?[]u8 = null,

    /// User input already copied out of ephemeral platform events but not yet
    /// accepted by the active PTY. Terminal protocol replies always flush
    /// before this queue, so backpressure cannot reorder or discard either.
    pending_child_bytes: std.ArrayList(u8) = .empty,
    pending_child_offset: usize = 0,

    /// What PTY integration checks watch, or null in every ordinary run: the
    /// bytes written to the child, the bytes it wrote back, and the last
    /// permission request. Borrowed from the check, which outlives every use.
    trace: ?*ClipboardTrace = null,

    fn init(
        io: Io,
        env: EnvSource,
        allocator: Allocator,
        window: *platform.Window,
        options: Options,
    ) !*App {
        const size = surfaceSize(window.state);
        var surface = try render.Surface.init(size);
        errdefer surface.deinit();
        const readback = try allocator.alloc(u8, render.readbackLen(size));
        errdefer allocator.free(readback);
        const input = try allocator.alloc(u8, pty_read_capacity);
        errdefer allocator.free(input);
        const output = try allocator.alloc(u8, term.response_capacity);
        errdefer allocator.free(output);

        const scale = window.state.scale.factor;
        const atlas = render.AtlasSize{ .width_px = atlas_width_px, .height_px = atlas_height_px };
        const colors = gridColors(default_palette);

        // Opening a face means walking every font directory on the machine and
        // asking FreeType about every file in it, which is a lot of IO. It runs
        // on a worker and is waited for once, here, before the first frame:
        // there is nothing to draw until a face exists, and a startup that is
        // not yet the loop is allowed to wait.
        var fonts = loaded: {
            const job = try allocator.create(Load);
            errdefer allocator.destroy(job);
            job.* = .{
                .allocator = allocator,
                .io = io,
                .font_request = .{
                    .family = options.run.font_family,
                    .size = try font.Size.init(font_points, scale),
                    .home_dir = env.get("HOME"),
                    .atlas_width_px = atlas_width_px,
                    .atlas_height_px = atlas_height_px,
                },
            };
            try job.start();
            job.thread.?.join();
            job.thread = null;
            if (job.font_failure) |name| log.warn("the font could not be loaded: {s}", .{name});
            const loaded_fonts = job.fonts orelse return error.NoFaceAvailable;
            job.fonts = null;
            allocator.destroy(job);
            break :loaded loaded_fonts;
        };
        errdefer fonts.deinit();
        log.info("drawing with {s}, {d}x{d}px cells, from {s}{s}", .{
            fonts.familyName(),
            fonts.metrics().cell.width_px,
            fonts.metrics().cell.height_px,
            fonts.sourcePath(),
            if (fonts.isFallback()) " (fallback)" else "",
        });

        const canvas_size = try gridSizeFor(fonts.metrics().cell, size);
        const sidebar_visible = sidebarStartsVisible(options);
        const sidebar_cols = sidebarColumns(canvas_size.cols, sidebar_default_width, sidebar_visible);
        const grid_size = try term.GridSize.init(canvas_size.cols - sidebar_cols, canvas_size.rows);
        var workspace_state = try workspace.Workspace.initLocal(
            io,
            allocator,
            "default",
            "",
            grid_size,
        );
        var workspace_state_owned = true;
        errdefer if (workspace_state_owned) workspace_state.deinit() catch |err| log.err("could not release the initializing workspace: {s}", .{@errorName(err)});
        const active_session_id = try workspace_state.createSession(.human_terminal, grid_size);
        _ = try workspace_state.registerTab("Terminal 1", active_session_id);
        const live = workspace_state.sessionById(active_session_id) orelse return error.SessionNotFound;
        // OSC 52 reaches the native clipboard only through this adapter and
        // only when policy is `.allow`; the default for both directions is
        // `.ask`, which M1 refuses because it has no prompt to ask with.
        live.terminal().setClipboardAccess(.{ .read_fn = readNativeClipboard, .write_fn = writeNativeClipboard });

        var initial_grid = try render.Grid.init(allocator, colors);
        var initial_grid_owned = true;
        errdefer if (initial_grid_owned) initial_grid.deinit();
        try initial_grid.attachAtlas(fonts.atlasPixels(), atlas);
        var pane_renderers: std.ArrayList(PaneRenderer) = .empty;
        errdefer pane_renderers.deinit(allocator);
        try pane_renderers.ensureUnusedCapacity(allocator, 1);
        pane_renderers.appendAssumeCapacity(.{
            .session_id = active_session_id,
            .grid = initial_grid,
        });
        initial_grid_owned = false;
        errdefer pane_renderers.items[0].deinit();

        var overlay_grid = try render.Grid.init(allocator, colors);
        errdefer overlay_grid.deinit();
        try overlay_grid.attachAtlas(fonts.atlasPixels(), atlas);

        var scratchpad_grid = try render.Grid.init(allocator, colors);
        errdefer scratchpad_grid.deinit();
        try scratchpad_grid.attachAtlas(fonts.atlasPixels(), atlas);

        const pane_layouts = try allocator.alloc(workspace.PaneLayout, sidebar_element_capacity);
        errdefer allocator.free(pane_layouts);
        const divider_layouts = try allocator.alloc(workspace.DividerLayout, sidebar_element_capacity);
        errdefer allocator.free(divider_layouts);

        var ui_canvas = try ui.Canvas.init(allocator, canvas_size.cols, canvas_size.rows);
        errdefer ui_canvas.deinit();
        var ui_tree = try ui.Tree.init(allocator, semantic_element_capacity, 6);
        errdefer ui_tree.deinit();

        const action_capacity: usize = if (options.run.ui_test or options.run.driver_test) 49 else 48;
        const action_definitions = try allocator.alloc(inputmod.ActionDefinition, action_capacity);
        errdefer allocator.free(action_definitions);
        var actions = inputmod.Registry.init(action_definitions);
        try actions.register(.{
            .name = clipboard_copy_action,
            .label = "Copy",
            .handler = clipboardCopyAction,
        });
        try actions.register(.{
            .name = clipboard_paste_action,
            .label = "Paste",
            .handler = clipboardPasteAction,
        });
        try actions.register(.{
            .name = sidebar_toggle_action,
            .label = "Toggle sidebar",
            .handler = sidebarToggleAction,
        });
        try actions.register(.{
            .name = sidebar_narrow_action,
            .label = "Narrow sidebar",
            .handler = sidebarNarrowAction,
        });
        try actions.register(.{
            .name = sidebar_widen_action,
            .label = "Widen sidebar",
            .handler = sidebarWidenAction,
        });
        try actions.register(.{
            .name = sidebar_focus_action,
            .label = "Focus sidebar",
            .handler = sidebarFocusAction,
        });
        try actions.register(.{
            .name = workspace_activate_action,
            .label = "Activate workspace",
            .handler = workspaceActivateAction,
            .palette = null,
        });
        try actions.register(.{
            .name = workspace_create_action,
            .label = "Create workspace",
            .handler = workspaceCreateAction,
            .palette = .{ .argument = .{ .input = .{
                .name = "directory",
                .prompt = "Working directory",
            } } },
        });
        try actions.register(.{
            .name = workspace_rename_action,
            .label = "Rename workspace",
            .handler = workspaceRenameAction,
            .palette = .{ .argument = .{ .input = .{
                .name = "name",
                .prompt = "Workspace name",
            } } },
        });
        try actions.register(.{
            .name = workspace_switch_action,
            .label = "Switch workspace",
            .handler = workspaceSwitchAction,
            .palette = .{ .argument = .{ .input = .{
                .name = "name",
                .prompt = "Exact workspace name",
            } } },
        });
        try actions.register(.{
            .name = workspace_close_action,
            .label = "Close workspace",
            .handler = workspaceCloseAction,
        });
        try actions.register(.{
            .name = workspace_close_confirm_action,
            .label = "Confirm workspace close",
            .handler = workspaceCloseConfirmAction,
            .palette = null,
        });
        try actions.register(.{
            .name = workspace_close_cancel_action,
            .label = "Cancel workspace close",
            .handler = workspaceCloseCancelAction,
            .palette = null,
        });
        try actions.register(.{
            .name = tab_activate_action,
            .label = "Activate tab",
            .handler = tabActivateAction,
            .palette = null,
        });
        try actions.register(.{
            .name = tab_new_action,
            .label = "New tab",
            .handler = tabNewAction,
        });
        try actions.register(.{
            .name = tab_close_action,
            .label = "Close tab",
            .handler = tabCloseAction,
        });
        try actions.register(.{
            .name = tab_close_confirm_action,
            .label = "Close running tab",
            .handler = tabCloseConfirmAction,
            .palette = null,
        });
        try actions.register(.{
            .name = tab_close_cancel_action,
            .label = "Keep tab open",
            .handler = tabCloseCancelAction,
            .palette = null,
        });
        try actions.register(.{
            .name = tab_rename_action,
            .label = "Rename tab",
            .handler = tabRenameAction,
        });
        try actions.register(.{
            .name = tab_rename_commit_action,
            .label = "Save tab name",
            .handler = tabRenameCommitAction,
            .palette = null,
        });
        try actions.register(.{
            .name = tab_rename_cancel_action,
            .label = "Cancel tab rename",
            .handler = tabRenameCancelAction,
            .palette = null,
        });
        try actions.register(.{
            .name = tab_previous_action,
            .label = "Previous tab",
            .handler = tabPreviousAction,
        });
        try actions.register(.{
            .name = tab_next_action,
            .label = "Next tab",
            .handler = tabNextAction,
        });
        try actions.register(.{
            .name = tab_goto_action,
            .label = "Go to tab",
            .handler = tabGotoAction,
            .palette = .{ .argument = .{ .input = .{
                .name = "index",
                .prompt = "Tab number",
            } } },
        });
        try actions.register(.{
            .name = tab_move_action,
            .label = "Move tab",
            .handler = tabMoveAction,
            .palette = .{ .argument = .{ .choices = .{
                .name = "direction",
                .prompt = "Move tab",
                .values = &tab_move_choices,
            } } },
        });
        try actions.register(.{
            .name = tab_reorder_action,
            .label = "Reorder tab",
            .handler = tabReorderAction,
            .palette = null,
        });
        try actions.register(.{
            .name = sidebar_resize_action,
            .label = "Resize sidebar",
            .handler = sidebarResizeAction,
            .palette = null,
        });
        try actions.register(.{
            .name = pane_activate_action,
            .label = "Activate pane",
            .handler = paneActivateAction,
            .palette = null,
        });
        try actions.register(.{
            .name = pane_split_action,
            .label = "Split pane",
            .handler = paneSplitAction,
            .palette = .{ .argument = .{ .choices = .{
                .name = "direction",
                .prompt = "Split pane",
                .values = &pane_split_choices,
            } } },
        });
        try actions.register(.{
            .name = pane_focus_action,
            .label = "Focus pane",
            .handler = paneFocusAction,
            .palette = .{ .argument = .{ .choices = .{
                .name = "direction",
                .prompt = "Focus pane",
                .values = &pane_direction_choices,
            } } },
        });
        try actions.register(.{
            .name = pane_resize_action,
            .label = "Resize pane",
            .handler = paneResizeAction,
            .palette = .{ .argument = .{ .choices = .{
                .name = "direction",
                .prompt = "Resize pane",
                .values = &pane_direction_choices,
            } } },
        });
        try actions.register(.{
            .name = pane_zoom_action,
            .label = "Zoom pane",
            .handler = paneZoomAction,
        });
        try actions.register(.{
            .name = pane_close_action,
            .label = "Close pane",
            .handler = paneCloseAction,
        });
        try actions.register(.{
            .name = scratchpad_toggle_50_action,
            .label = "Scratchpad: Toggle 50%",
            .handler = scratchpadToggle50Action,
        });
        try actions.register(.{
            .name = scratchpad_toggle_90_action,
            .label = "Scratchpad: Toggle 90%",
            .handler = scratchpadToggle90Action,
        });
        try actions.register(.{
            .name = scratchpad_restart_action,
            .label = "Scratchpad: Restart Session",
            .handler = scratchpadRestartAction,
        });
        try actions.register(.{
            .name = scratchpad_hide_action,
            .label = "Scratchpad: Hide",
            .handler = scratchpadHideAction,
        });
        try actions.register(.{
            .name = palette_open_action,
            .label = "Open command palette",
            .handler = paletteOpenAction,
            .palette = null,
        });
        try actions.register(.{
            .name = palette_activate_action,
            .label = "Activate palette selection",
            .handler = paletteActivateAction,
            .palette = null,
        });
        try actions.register(.{
            .name = terminal_open_link_action,
            .label = "Open terminal link",
            .handler = terminalOpenLinkAction,
            .palette = null,
        });
        try actions.register(.{
            .name = search_open_action,
            .label = "Open terminal search",
            .handler = searchOpenAction,
        });
        try actions.register(.{
            .name = search_close_action,
            .label = "Close terminal search",
            .handler = searchCloseAction,
            .palette = null,
        });
        try actions.register(.{
            .name = search_next_action,
            .label = "Search: Next match",
            .handler = searchNextAction,
        });
        try actions.register(.{
            .name = search_previous_action,
            .label = "Search: Previous match",
            .handler = searchPreviousAction,
        });
        try actions.register(.{
            .name = search_case_action,
            .label = "Search: Toggle case sensitivity",
            .handler = searchCaseAction,
        });
        try actions.register(.{
            .name = search_regex_action,
            .label = "Search: Toggle regex",
            .handler = searchRegexAction,
        });
        try actions.register(.{
            .name = search_activate_match_action,
            .label = "Activate search match",
            .handler = searchActivateMatchAction,
            .palette = null,
        });
        try actions.register(.{
            .name = terminal_context_menu_action,
            .label = "Open terminal context menu",
            .handler = terminalContextMenuAction,
        });
        if (options.run.ui_test or options.run.driver_test) try actions.register(.{
            .name = ui_test_activate_action,
            .label = "Activate UI test action",
            .handler = uiTestActivateAction,
            .palette = null,
        });

        const binding_profile = inputmod.PlatformProfile.native;
        const bindings = inputmod.defaultBindings(binding_profile);
        const binding_keys = try allocator.alloc(inputmod.BindingKey, @max(bindings.len, 4));
        errdefer allocator.free(binding_keys);

        var palette_model = try palette_mod.Model.init(allocator, actions.definitions());
        errdefer palette_model.deinit();
        palette_model.refresh("");
        var palette_query = try ui.Input.init(allocator, palette_input_capacity, "");
        errdefer palette_query.deinit();
        var palette_argument = try ui.Input.init(allocator, palette_input_capacity, "");
        errdefer palette_argument.deinit();
        var search_query = try ui.Input.init(allocator, term.max_search_needle_bytes, "");
        errdefer search_query.deinit();

        var spec: ChildSpec = .{ .allocator = allocator, .argv = &.{}, .env = &.{} };
        errdefer spec.deinit();
        if (wantsChild(options)) {
            spec = try ChildSpec.build(allocator, io, env, options);
        }
        const deterministic_scratchpad = usesDeterministicScratchpad(options);
        var scratchpad_spec = try ChildSpec.buildInteractive(
            allocator,
            io,
            env,
            options.run.no_shell_integration or deterministic_scratchpad,
            if (deterministic_scratchpad) "/bin/sh" else null,
        );
        errdefer scratchpad_spec.deinit();

        var workspace_registry = workspace.WorkspaceRegistry.init(allocator);
        errdefer workspace_registry.deinit() catch |err| log.err("could not release the initializing workspace registry: {s}", .{@errorName(err)});
        const workspace_key = try workspace_registry.insert(&workspace_state);
        workspace_state_owned = false;

        var workspace_presentations: std.ArrayList(*WorkspacePresentation) = .empty;
        errdefer workspace_presentations.deinit(allocator);
        try workspace_presentations.ensureUnusedCapacity(allocator, 1);
        const initial_presentation = try allocator.create(WorkspacePresentation);
        errdefer allocator.destroy(initial_presentation);
        initial_presentation.* = .{
            .key = workspace_key,
            .active_session_id = active_session_id,
            .pane_renderers = pane_renderers,
            .scratchpad_grid = scratchpad_grid,
        };
        workspace_presentations.appendAssumeCapacity(initial_presentation);

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);
        app.* = .{
            .allocator = allocator,
            .io = io,
            .window = window,
            .surface = surface,
            .size = size,
            .readback = readback,
            .background = colors.background,
            .needs_present = true,
            .scheduler = Scheduler.init(options.run.force_redraw),
            .fonts = fonts,
            .workspace_registry = workspace_registry,
            .workspace_presentations = workspace_presentations,
            .overlay_grid = overlay_grid,
            .pane_layouts = pane_layouts,
            .divider_layouts = divider_layouts,
            .spec = spec,
            .scratchpad_spec = scratchpad_spec,
            .input = input,
            .output = output,
            .child_input = .{},
            .composition = .{},
            .ui_canvas = ui_canvas,
            .ui_tree = ui_tree,
            .action_definitions = action_definitions,
            .actions = actions,
            .palette_model = palette_model,
            .palette_query = palette_query,
            .palette_argument = palette_argument,
            .search_query = search_query,
            .right_click = config.Layer.resolve(config.RightClick, config.RightClick.built_in, null, options.run.right_click),
            .binding_profile = binding_profile,
            .bindings = bindings,
            .binding_keys = binding_keys,
            .binding_state = inputmod.BindingState.init(binding_keys),
            .sidebar_enabled = sidebarEnabled(options),
            .sidebar_visible = sidebar_visible,
            .sidebar_width_cols = sidebar_default_width,
            .pending_committed_text = "",
            .pending_child_bytes = .empty,
            .pending_child_offset = 0,
            .font_load = null,
            .family = options.run.font_family,
            .font_scale = scale,
            .home_dir = env.get("HOME"),
            .blink_epoch_ns = Io.Clock.real.now(io).nanoseconds,
            .blink_visible = true,
            .exit_with_child = options.run.command != null,
            .spawn_finished = spec.argv.len == 0,
            .exit_logged = false,
            .screenshot = options.run.screenshot,
            .driver_artifact_dir = options.run.test_artifact_dir,
        };
        try app.syncGrid();
        if (testdriver.isEnabled(options.run.test_driver_endpoint != null)) {
            const endpoint = options.run.test_driver_endpoint.?;
            app.driver = try platform.DriverTransport.start(allocator, endpoint, window);
            log.info("test driver listening on a local endpoint", .{});
        }
        // Start the worker only after every fallible initialization step. On
        // an earlier error the local errdefers own cleanup; once this starts,
        // the returned App owns and joins it during deinit.
        app.startScratchpad(false);
        app.startChild();
        return app;
    }

    fn presentationByKey(self: *App, key: workspace.WorkspaceKey) ?*WorkspacePresentation {
        for (self.workspace_presentations.items) |presentation| {
            if (presentation.key == key) return presentation;
        }
        return null;
    }

    fn presentationByKeyConst(self: *const App, key: workspace.WorkspaceKey) ?*const WorkspacePresentation {
        for (self.workspace_presentations.items) |presentation| {
            if (presentation.key == key) return presentation;
        }
        return null;
    }

    fn activePresentation(self: *App) *WorkspacePresentation {
        const key = self.workspace_registry.activeKey() orelse unreachable;
        return self.presentationByKey(key) orelse unreachable;
    }

    fn activePresentationConst(self: *const App) *const WorkspacePresentation {
        const key = self.workspace_registry.activeKey() orelse unreachable;
        return self.presentationByKeyConst(key) orelse unreachable;
    }

    fn activeWorkspace(self: *App) *workspace.Workspace {
        return self.workspace_registry.active() orelse unreachable;
    }

    fn activeWorkspaceConst(self: *const App) *const workspace.Workspace {
        return @constCast(&self.workspace_registry).active() orelse unreachable;
    }

    fn activeLive(self: *App) *session.Session {
        const presentation = self.activePresentation();
        return self.activeWorkspace().sessionById(presentation.active_session_id) orelse unreachable;
    }

    fn activeLiveConst(self: *const App) *session.Session {
        const presentation = self.activePresentationConst();
        return @constCast(self.activeWorkspaceConst()).sessionById(presentation.active_session_id) orelse unreachable;
    }

    fn destroyLoad(self: *App, job: *Load) void {
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
        if (job.child) |child| {
            destroyUnattachedChild(child);
            job.child = null;
        }
        if (job.fonts) |*fonts| {
            fonts.deinit();
            job.fonts = null;
        }
        job.freeSpawnInputs();
        self.allocator.destroy(job);
    }

    /// Give back everything the app owns, in the reverse of the order it was
    /// built. The window belongs to `main`, which outlives the app.
    fn deinit(self: *App) void {
        if (self.driver) |driver| {
            driver.stop();
            // SDL text-input events borrow the retained request bytes. Consume
            // every already-posted event before those arenas are released.
            while (self.window.pump(0) != null) {}
            driver.deinit();
            self.driver = null;
        }
        for (&self.driver_pending) |*slot| {
            if (slot.*) |*pending| pending.deinit(self.allocator);
            slot.* = null;
        }
        self.window.stopTextInput() catch |err| {
            log.warn("could not stop text input: {s}", .{@errorName(err)});
        };
        if (self.font_load) |job| self.destroyLoad(job);
        for (self.workspace_presentations.items) |presentation| {
            if (presentation.load) |job| self.destroyLoad(job);
            if (presentation.scratchpad_load) |job| self.destroyLoad(job);
        }
        self.stopSearchEngine();
        if (self.rename_input) |*field| field.deinit();
        self.search_query.deinit();
        self.palette_argument.deinit();
        self.palette_query.deinit();
        self.palette_model.deinit();
        self.spec.deinit();
        self.scratchpad_spec.deinit();
        if (self.pending_paste) |bytes| self.allocator.free(bytes);
        self.pending_child_bytes.deinit(self.allocator);
        self.ui_tree.deinit();
        self.ui_canvas.deinit();
        self.allocator.free(self.binding_keys);
        self.allocator.free(self.action_definitions);
        self.overlay_grid.deinit();
        for (self.workspace_presentations.items) |presentation| {
            for (presentation.pane_renderers.items) |*pane_renderer| pane_renderer.deinit();
            presentation.pane_renderers.deinit(self.allocator);
            presentation.scratchpad_grid.deinit();
            self.allocator.destroy(presentation);
        }
        self.workspace_presentations.deinit(self.allocator);
        self.workspace_registry.deinit() catch |err| {
            log.warn("could not signal a child during workspace shutdown: {s}", .{@errorName(err)});
        };
        self.allocator.free(self.pane_layouts);
        self.allocator.free(self.divider_layouts);
        self.fonts.deinit();
        self.allocator.free(self.input);
        self.allocator.free(self.output);
        self.allocator.free(self.readback);
        self.surface.deinit();
        self.* = undefined;
    }

    /// Release the app's owned resources and its allocator-stable storage.
    fn destroy(self: *App) void {
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    /// Start the child, on a worker, at the grid's size.
    ///
    /// A failure is a log line and a run with no child rather than a failed
    /// app: the window is open and the grid draws whatever the terminal has,
    /// and a machine with no shell to run is not a reason to crash.
    fn startChild(self: *App) void {
        if (self.spec.argv.len == 0) return;
        const presentation = self.activePresentation();
        self.startPresentationChild(presentation, presentation.active_session_id, .{
            .argv = self.spec.argv,
            .env = self.spec.env,
        });
    }

    fn startPresentationChild(
        self: *App,
        presentation: *WorkspacePresentation,
        session_id: session.SessionId,
        process: workspace.ProcessSpec,
    ) void {
        if (presentation.load != null) return;
        const model = self.workspace_registry.byKey(presentation.key) orelse unreachable;
        const request = model.spawnRequest(session_id, process) catch |err| {
            log.warn("could not prepare the child session: {s}", .{@errorName(err)});
            self.spawn_finished = true;
            return;
        };
        const job = self.allocator.create(Load) catch |err| {
            log.warn("no memory to start a child process: {s}", .{@errorName(err)});
            self.spawn_finished = true;
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .spawn = request,
            .spawn_session_id = session_id,
            .workspace_key = presentation.key,
            .execution_context = model.contextRef(),
        };
        job.start() catch |err| {
            log.warn("could not start the worker that spawns the child: {s}", .{@errorName(err)});
            self.allocator.destroy(job);
            self.spawn_finished = true;
            return;
        };
        presentation.load = job;
    }

    /// Start the reserved scratchpad, or spawn a transactional replacement,
    /// without occupying the ordinary tab/font worker slot.
    fn startScratchpad(self: *App, replacement: bool) void {
        const presentation = self.activePresentation();
        self.startScratchpadFor(presentation, replacement);
    }

    fn startScratchpadFor(self: *App, presentation: *WorkspacePresentation, replacement: bool) void {
        if (presentation.scratchpad_load != null) {
            log.warn("scratchpad start deferred while another scratchpad load is in flight", .{});
            return;
        }
        const model = self.workspace_registry.byKey(presentation.key) orelse unreachable;
        const process: workspace.ProcessSpec = .{
            .argv = self.scratchpad_spec.argv,
            .env = self.scratchpad_spec.env,
        };
        const request = if (replacement)
            model.scratchpadRestartRequest(process) catch |err| {
                log.warn("could not prepare the scratchpad restart: {s}", .{@errorName(err)});
                return;
            }
        else
            model.spawnRequest(model.scratchpadId(), process) catch |err| {
                log.warn("could not prepare the scratchpad session: {s}", .{@errorName(err)});
                return;
            };
        const job = self.allocator.create(Load) catch |err| {
            log.warn("no memory to start the scratchpad: {s}", .{@errorName(err)});
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .spawn = request,
            .spawn_session_id = model.scratchpadId(),
            .workspace_key = presentation.key,
            .scratchpad_replacement = replacement,
            .execution_context = model.contextRef(),
        };
        job.start() catch |err| {
            log.warn("could not start the scratchpad spawn worker: {s}", .{@errorName(err)});
            self.allocator.destroy(job);
            return;
        };
        presentation.scratchpad_load = job;
    }

    fn destroyUnattachedChild(child: pty.Pty) void {
        child.kill(.hangup) catch |kill_err| switch (kill_err) {
            error.Closed => {},
            else => log.warn("could not signal an unattached scratchpad child: {s}", .{@errorName(kill_err)}),
        };
        child.destroy();
    }

    /// Collect one workspace's scratchpad startup/restart without blocking the
    /// UI thread. Selection may have changed since this worker was started.
    fn pollScratchpadLoadFor(self: *App, presentation: *WorkspacePresentation) bool {
        const job = presentation.scratchpad_load orelse return false;
        if (!job.finished()) return false;
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
        const model = self.workspace_registry.byKey(presentation.key) orelse {
            self.destroyLoad(job);
            presentation.scratchpad_load = null;
            return false;
        };
        if (job.workspace_key == null or job.workspace_key.? != presentation.key) {
            log.err("scratchpad worker result was attributed to the wrong workspace", .{});
            self.destroyLoad(job);
            presentation.scratchpad_load = null;
            return false;
        }
        if (presentation.closing) {
            self.destroyLoad(job);
            presentation.scratchpad_load = null;
            return true;
        }
        var changed = false;
        if (job.child) |child| {
            if (job.scratchpad_replacement) {
                const replaced = model.replaceScratchpad(child) catch |err| {
                    log.warn("scratchpad restart did not commit: {s}", .{@errorName(err)});
                    destroyUnattachedChild(child);
                    job.child = null;
                    job.freeSpawnInputs();
                    self.allocator.destroy(job);
                    presentation.scratchpad_load = null;
                    return false;
                };
                job.child = null;
                if (replaced.old_child_deinit_error) |err| {
                    log.warn("the old scratchpad could not be signalled cleanly after replacement: {s}", .{@errorName(err)});
                }
            } else {
                model.attachChild(model.scratchpadId(), child) catch |err| {
                    log.warn("could not attach the scratchpad child: {s}", .{@errorName(err)});
                    destroyUnattachedChild(child);
                    job.child = null;
                    job.freeSpawnInputs();
                    self.allocator.destroy(job);
                    presentation.scratchpad_load = null;
                    return false;
                };
                job.child = null;
            }
            if (model.sessionById(model.scratchpadId())) |scratchpad| {
                scratchpad.terminal().setClipboardAccess(.{
                    .read_fn = readNativeClipboard,
                    .write_fn = writeNativeClipboard,
                });
            }
            presentation.scratchpad_grid.invalidate();
            changed = true;
        }
        if (job.spawn_failure) |name| {
            log.warn("no scratchpad child process: {s}; the previous session remains available", .{name});
        }
        job.freeSpawnInputs();
        self.allocator.destroy(job);
        presentation.scratchpad_load = null;
        return changed;
    }

    fn pollScratchpadLoad(self: *App) bool {
        var changed = false;
        for (self.workspace_presentations.items) |presentation| {
            changed = self.pollScratchpadLoadFor(presentation) or changed;
        }
        return changed;
    }

    fn newPaneRenderer(self: *App, session_id: session.SessionId) !PaneRenderer {
        var grid = try render.Grid.init(self.allocator, gridColors(default_palette));
        errdefer grid.deinit();
        try grid.attachAtlas(self.fonts.atlasPixels(), .{
            .width_px = atlas_width_px,
            .height_px = atlas_height_px,
        });
        return .{ .session_id = session_id, .grid = grid };
    }

    fn rendererForSession(self: *App, session_id: session.SessionId) ?*render.Grid {
        for (self.activePresentation().pane_renderers.items) |*record| {
            if (record.session_id == session_id) return &record.grid;
        }
        return null;
    }

    fn focusedGrid(self: *App) *render.Grid {
        return if (self.scratchpadVisible())
            &self.activePresentation().scratchpad_grid
        else
            self.rendererForSession(self.activePresentation().active_session_id) orelse &self.overlay_grid;
    }

    fn discardClosedPaneRenderers(self: *App) void {
        var index: usize = 0;
        while (index < self.activePresentation().pane_renderers.items.len) {
            const record = &self.activePresentation().pane_renderers.items[index];
            if (self.activeWorkspace().paneForSession(record.session_id) != null and
                self.activeWorkspace().sessionById(record.session_id) != null)
            {
                index += 1;
                continue;
            }
            record.deinit();
            _ = self.activePresentation().pane_renderers.orderedRemove(index);
        }
    }

    /// Start one newly created tab from a cwd copied before selection changed.
    /// Ownership of `cwd` transfers on entry and remains with the Load until
    /// its worker has joined, including every failure path.
    fn startTabChild(self: *App, session_id: session.SessionId, cwd: []u8) void {
        self.startTabChildWith(session_id, cwd, null);
    }

    /// Start one newly created tab with `argv` owned by the job instead of the
    /// app-level child spec, or with that spec when `argv` is null. Ownership
    /// of `cwd` and `argv` transfers on entry and remains with the Load until
    /// its worker has joined, including every failure path.
    fn startTabChildWith(self: *App, session_id: session.SessionId, cwd: []u8, argv: ?[][]const u8) void {
        const program = argv orelse self.spec.argv;
        if (program.len == 0) {
            self.allocator.free(cwd);
            if (argv) |owned| freeEntries(self.allocator, owned);
            return;
        }
        const presentation = self.activePresentation();
        if (presentation.load != null) {
            log.warn("a tab child was not started because another load is still in flight", .{});
            self.allocator.free(cwd);
            if (argv) |owned| freeEntries(self.allocator, owned);
            return;
        }
        const model = self.workspace_registry.byKey(presentation.key) orelse unreachable;
        var request = model.spawnRequest(session_id, .{
            .argv = program,
            .env = self.spec.env,
        }) catch |err| {
            log.warn("could not prepare the new tab child: {s}", .{@errorName(err)});
            self.allocator.free(cwd);
            if (argv) |owned| freeEntries(self.allocator, owned);
            return;
        };
        request.cwd = cwd;
        const job = self.allocator.create(Load) catch |err| {
            log.warn("no memory to start the new tab child: {s}", .{@errorName(err)});
            self.allocator.free(cwd);
            if (argv) |owned| freeEntries(self.allocator, owned);
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .spawn = request,
            .spawn_cwd = cwd,
            .spawn_argv = argv,
            .spawn_session_id = session_id,
            .workspace_key = presentation.key,
            .execution_context = model.contextRef(),
        };
        job.start() catch |err| {
            log.warn("could not start the worker for the new tab: {s}", .{@errorName(err)});
            job.freeSpawnInputs();
            self.allocator.destroy(job);
            return;
        };
        presentation.load = job;
    }

    /// Ask a worker for a face rasterised at the display scale the window is
    /// on now.
    ///
    /// A face rasterised for one scale is blurry on the next, so it has to be
    /// rasterised again rather than scaled up. The request is polled by the
    /// loop instead of waited on, so the frame that notices the window moved is
    /// not the frame that blocks on the scan.
    fn requestFontReload(self: *App) void {
        if (self.font_load != null) {
            log.debug("a load is already in flight; the new scale will be picked up by it", .{});
            return;
        }
        const size = font.Size.init(font_points, self.font_scale) catch |err| {
            log.err("a display scale of {d:.2} is not a usable font size: {s}", .{
                self.font_scale,
                @errorName(err),
            });
            return;
        };
        const job = self.allocator.create(Load) catch |err| {
            log.warn("no memory to re-load the font: {s}", .{@errorName(err)});
            return;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .font_request = .{
                .family = self.family,
                .size = size,
                .home_dir = self.home_dir,
                .atlas_width_px = atlas_width_px,
                .atlas_height_px = atlas_height_px,
            },
        };
        job.start() catch |err| {
            log.warn("could not start the worker that re-loads the font: {s}", .{@errorName(err)});
            self.allocator.destroy(job);
            return;
        };
        self.font_load = job;
        log.info("re-loading the face at display scale {d:.2}", .{self.font_scale});
    }

    /// Take whatever a finished job produced, and say whether the screen has to
    /// be redrawn as a result.
    fn pollPresentationLoad(self: *App, presentation: *WorkspacePresentation) bool {
        const job = presentation.load orelse return false;
        if (!job.finished()) return false;
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
        const model = self.workspace_registry.byKey(presentation.key) orelse {
            self.destroyLoad(job);
            presentation.load = null;
            return false;
        };
        if (job.workspace_key == null or job.workspace_key.? != presentation.key) {
            log.err("child worker result was attributed to the wrong workspace", .{});
            self.destroyLoad(job);
            presentation.load = null;
            return false;
        }
        if (presentation.closing) {
            self.destroyLoad(job);
            presentation.load = null;
            return true;
        }
        if (job.child) |child| {
            const target_id = job.spawn_session_id orelse presentation.active_session_id;
            if (job.spawn_session_id != null and model.sessionById(target_id) == null) {
                // Closing a starting pane cannot cancel the worker synchronously.
                // Its eventual child is still ours and must be reaped instead of
                // being attached to a session that deliberately no longer exists.
                child.kill(.hangup) catch |kill_err| switch (kill_err) {
                    error.Closed => {},
                    else => log.warn("could not signal the canceled child: {s}", .{@errorName(kill_err)}),
                };
                child.destroy();
            } else {
                model.attachChild(target_id, child) catch |err| {
                    // A spawn job exists only while this session has no child, so
                    // every failure for a session that still exists is an
                    // ownership invariant. The new handle is still ours on
                    // failure and must not leak or leave its process behind.
                    log.err("could not attach the spawned child: {s}", .{@errorName(err)});
                    child.kill(.hangup) catch |kill_err| switch (kill_err) {
                        error.Closed => {},
                        else => log.warn("could not signal the unattached child: {s}", .{@errorName(kill_err)}),
                    };
                    child.destroy();
                };
            }
            job.child = null;
            if (model.sessionById(target_id)) |target| if (target.child() != null) {
                const grid = target.terminal().gridSize();
                log.info("child started, window {d}x{d} cells", .{ grid.cols, grid.rows });
            };
        }
        if (job.spawn != null) self.spawn_finished = true;
        if (job.spawn_failure) |name| {
            log.warn("no child process: {s}; the terminal stays empty", .{name});
        }
        job.freeSpawnInputs();
        self.allocator.destroy(job);
        presentation.load = null;
        return false;
    }

    fn pollFontLoad(self: *App) bool {
        const job = self.font_load orelse return false;
        if (!job.finished()) return false;
        if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        }
        var changed = false;
        if (job.fonts) |fonts| {
            self.fonts.deinit();
            self.fonts = fonts;
            job.fonts = null;
            for (self.workspace_presentations.items) |presentation| {
                for (presentation.pane_renderers.items) |*pane_renderer| {
                    pane_renderer.grid.attachAtlas(self.fonts.atlasPixels(), .{
                        .width_px = atlas_width_px,
                        .height_px = atlas_height_px,
                    }) catch |err| log.err("the new face could not be uploaded: {s}", .{@errorName(err)});
                }
                presentation.scratchpad_grid.attachAtlas(self.fonts.atlasPixels(), .{
                    .width_px = atlas_width_px,
                    .height_px = atlas_height_px,
                }) catch |err| log.err("the new scratchpad face could not be uploaded: {s}", .{@errorName(err)});
            }
            self.overlay_grid.attachAtlas(self.fonts.atlasPixels(), .{
                .width_px = atlas_width_px,
                .height_px = atlas_height_px,
            }) catch |err| log.err("the new overlay face could not be uploaded: {s}", .{@errorName(err)});
            log.info("now drawing with {s}, {d}x{d}px cells", .{
                self.fonts.familyName(),
                self.fonts.metrics().cell.width_px,
                self.fonts.metrics().cell.height_px,
            });
            self.syncGrid() catch |err| {
                log.warn("the grid could not be resized for the new face: {s}", .{@errorName(err)});
            };
            changed = true;
        }
        if (job.font_failure) |name| log.warn("the font could not be loaded: {s}", .{name});
        job.freeSpawnInputs();
        self.allocator.destroy(job);
        self.font_load = null;
        return changed;
    }

    fn pollLoad(self: *App) bool {
        var changed = self.pollFontLoad();
        for (self.workspace_presentations.items) |presentation| {
            changed = self.pollPresentationLoad(presentation) or changed;
        }
        return changed;
    }

    /// Bring the surface, the grid and the readback buffer to the size a window
    /// state implies, rebuilding only what actually moved.
    fn syncSurface(self: *App, state: platform.State) !void {
        const wanted = surfaceSize(state);
        if (!wanted.eql(self.size)) {
            try self.surface.resize(wanted);
            self.size = wanted;
            try self.growReadback();
            try self.syncGrid();
        }
        if (state.scale.factor != self.font_scale) {
            self.font_scale = state.scale.factor;
            self.requestFontReload();
        }
        // A resize or a scale change that lands on the size already in use still
        // invalidates: the window moved, and what is on screen has to be
        // redrawn even though the texture did not change.
        self.scheduler.invalidate();
        self.needs_present = true;
    }

    /// Fit the grid to the surface with the face the app is drawing with.
    fn syncGrid(self: *App) !void {
        const canvas_size = try gridSizeFor(self.fonts.metrics().cell, self.size);
        const origin = sidebarColumns(canvas_size.cols, self.sidebar_width_cols, self.sidebar_visible);
        const canvas_bounds = self.ui_canvas.bounds();
        if (canvas_bounds.width != canvas_size.cols or canvas_bounds.height != canvas_size.rows) {
            try self.ui_canvas.resize(canvas_size.cols, canvas_size.rows);
        }
        // Scratchpad geometry is independent of whether the workspace has a
        // currently layoutable tab. A tiny sidebar or a transient empty tab
        // must not leave the presented PTY at the previous dock size.
        if (self.scratchpadInnerRect()) |inner| {
            if (self.scratchpadLive()) |scratchpad| {
                const wanted = try term.GridSize.init(@intCast(inner.width), @intCast(inner.height));
                const current = scratchpad.terminal().gridSize();
                if (wanted.cols != current.cols or wanted.rows != current.rows) {
                    try scratchpad.resize(wanted);
                    self.noteSearchTerminalChange(self.activeWorkspace().scratchpadId());
                }
            }
        }
        self.pane_layout_count = 0;
        self.divider_layout_count = 0;
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        const terminal_cols = canvas_size.cols -| origin;
        if (terminal_cols == 0 or canvas_size.rows == 0) return;
        const bounds = workspace.CellRect.init(origin, 0, terminal_cols, canvas_size.rows) catch return;
        self.pane_layout_count = self.activeWorkspace().layoutPanes(
            tab_id,
            bounds,
            self.pane_layouts,
        ) catch |err| switch (err) {
            error.InvalidGeometry => return,
            else => return err,
        };
        self.divider_layout_count = self.activeWorkspace().layoutDividers(
            tab_id,
            bounds,
            self.divider_layouts,
        ) catch |err| switch (err) {
            error.InvalidGeometry => 0,
            else => return err,
        };
        for (self.pane_layouts[0..self.pane_layout_count]) |layout| {
            const live = self.activeWorkspace().sessionById(layout.session_id) orelse continue;
            const wanted = try term.GridSize.init(layout.rect.cols, layout.rect.rows);
            const current = live.terminal().gridSize();
            if (wanted.cols != current.cols or wanted.rows != current.rows) {
                try live.resize(wanted);
                self.noteSearchTerminalChange(layout.session_id);
            }
        }
    }

    fn terminalCellBounds(self: *const App) ?workspace.CellRect {
        const bounds = self.ui_canvas.bounds();
        const origin = self.sidebarOriginColumns();
        const total_cols = std.math.cast(u16, bounds.width) orelse return null;
        const rows = std.math.cast(u16, bounds.height) orelse return null;
        const cols = total_cols -| origin;
        if (cols == 0 or rows == 0) return null;
        return workspace.CellRect.init(origin, 0, cols, rows) catch null;
    }

    fn focusedPaneLayout(self: *const App) ?workspace.PaneLayout {
        for (self.pane_layouts[0..self.pane_layout_count]) |layout| {
            if (layout.session_id == self.activePresentationConst().active_session_id) return layout;
        }
        return null;
    }

    fn scratchpadVisible(self: *const App) bool {
        return self.activePresentationConst().scratchpad_presentation != .hidden;
    }

    fn scratchpadLive(self: *App) ?*session.Session {
        return self.activeWorkspace().sessionById(self.activeWorkspace().scratchpadId());
    }

    fn scratchpadLiveConst(self: *const App) ?*const session.Session {
        const model = self.activeWorkspaceConst();
        return @constCast(model).sessionById(model.scratchpadId());
    }

    /// The bottom-docked outer box in terminal cells. A tiny surface cannot
    /// contain a one-cell border and a terminal, so it has no presentation.
    fn scratchpadBounds(self: *const App) ?ui.Rect {
        if (!self.scratchpadVisible()) return null;
        const canvas = self.ui_canvas.bounds();
        if (canvas.width < 3 or canvas.height < 3) return null;
        const percent = self.activePresentationConst().scratchpad_presentation.percent();
        const wanted = (canvas.height * percent + 99) / 100;
        const height = @min(canvas.height, @max(@as(u32, 3), wanted));
        return .{
            .x = 0,
            .y = canvas.height - height,
            .width = canvas.width,
            .height = height,
        };
    }

    fn scratchpadInnerRect(self: *const App) ?ui.Rect {
        const outer = self.scratchpadBounds() orelse return null;
        return .{
            .x = outer.x + 1,
            .y = outer.y + 1,
            .width = outer.width - 2,
            .height = outer.height - 2,
        };
    }

    fn paletteVisible(self: *const App) bool {
        return self.palette_step != .closed;
    }

    fn contextMenuVisible(self: *const App) bool {
        return self.context_menu != null;
    }

    fn contextMenuBoundsNow(self: *const App) ?ui.Rect {
        const menu = self.context_menu orelse return null;
        var storage: [context_menu_max_items]ContextMenuItem = undefined;
        const items = contextMenuItems(menu.has_selection, menu.linkId() != null, &storage);
        return contextMenuBounds(menu.col, menu.row, items.len, self.ui_canvas.bounds());
    }

    /// The menu is a `Surface` panel of `InteractiveText` rows registered once
    /// in the one semantic tree. It erases the terminal cells beneath it so
    /// the rows read as a panel rather than as text over text.
    fn composeContextMenu(self: *App) !void {
        const menu = self.context_menu orelse return;
        var storage: [context_menu_max_items]ContextMenuItem = undefined;
        const items = contextMenuItems(menu.has_selection, menu.linkId() != null, &storage);
        const bounds = contextMenuBounds(menu.col, menu.row, items.len, self.ui_canvas.bounds()) orelse return;
        const menu_id: ui.Id = .{ .value = "context-menu" };
        try self.ui_tree.addSurface(.{
            .id = menu_id,
            .role = "menu",
            .label = "Terminal context menu",
            .bounds = bounds,
        }, .{
            .rect = bounds,
            .erase_underlay = true,
            .fill = .background,
            .border = .single,
            .border_style = .{ .foreground = .bright_blue, .background = .background },
        });
        for (items, 0..) |item, index| {
            const id: ui.Id = .{ .value = item.id };
            try self.ui_tree.addInteractiveText(.{
                .id = id,
                .parent = menu_id,
                .role = "menu_item",
                .label = item.label,
                .action = item.action,
                .bounds = .{
                    .x = bounds.x + 2,
                    .y = bounds.y + 1 + @as(u32, @intCast(index)),
                    .width = bounds.width - 4,
                    .height = 1,
                },
            }, .{
                .id = id,
                .label = item.label,
                .action = item.action,
                .normal = .{ .foreground = .foreground, .background = .background },
                .hovered = .{ .foreground = .bright_white, .underline = .accent, .background = .background },
                .focused = .{ .foreground = .black, .background = .accent },
            });
        }
    }

    /// Open the menu anchored at a canvas cell. `link_id` borrows the current
    /// semantic frame and is copied before that frame is rebuilt. Nothing
    /// opens over another modal surface or while a gesture is in flight.
    fn openContextMenu(self: *App, col: u32, row: u32, link_id: ?[]const u8) !void {
        if (self.contextMenuVisible() or self.paletteVisible() or self.closeModalActive() or
            self.rename_tab_id != null or self.search_visible or self.scratchpadVisible() or
            self.ui_pointer_owned or self.sidebar_dragging or self.dragged_divider_id != null or
            self.dragged_tab_id != null) return;
        var menu: ContextMenu = .{
            .col = col,
            .row = row,
            .has_selection = self.presentedLive().terminal().hasSelection(),
        };
        if (link_id) |id| {
            if (id.len <= menu.link_id.len) {
                @memcpy(menu.link_id[0..id.len], id);
                menu.link_id_len = id.len;
            }
        }
        var storage: [context_menu_max_items]ContextMenuItem = undefined;
        const items = contextMenuItems(menu.has_selection, menu.linkId() != null, &storage);
        if (contextMenuBounds(col, row, items.len, self.ui_canvas.bounds()) == null) return;
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        try self.window.stopTextInput();
        self.context_menu = menu;
        self.ui_tree.clearFocus();
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = items[0].id })) try self.composeUi();
        try self.syncTextInput();
        self.invalidateUi();
    }

    /// Open the menu from the keyboard at the focused pane's cursor cell, so the
    /// keyboard path lands where the user is working rather than at a stale
    /// pointer. A link under that cell gets its `open link` row too.
    fn openContextMenuAtCursor(self: *App) !void {
        if (self.terminal_pointer_presses != 0 or self.context_menu_pointer_owned) return;
        const layout = self.focusedPaneLayout() orelse return;
        const cursor = self.presentedLive().terminal().cursor();
        const position = cursor.position orelse term.Position{ .col = 0, .row = 0 };
        const col = @as(u32, layout.rect.col) + @min(@as(u32, position.col), @as(u32, layout.rect.cols) -| 1);
        const row = @as(u32, layout.rect.row) + @min(@as(u32, position.row), @as(u32, layout.rect.rows) -| 1);
        const cell = self.fonts.metrics().cell;
        const point: ui.Point = .{
            .x = @intCast(col * cell.width_px + cell.width_px / 2),
            .y = @intCast(row * cell.height_px + cell.height_px / 2),
        };
        const link_id: ?[]const u8 = if (self.ui_tree.hitTest(point)) |hit|
            (if (isTerminalLink(hit)) hit.id.value else null)
        else
            null;
        try self.openContextMenu(col, row, link_id);
    }

    fn closeContextMenu(self: *App) !void {
        if (!self.contextMenuVisible()) return;
        self.context_menu = null;
        self.ui_tree.clearFocus();
        try self.composeUi();
        try self.syncTextInput();
        self.invalidateUi();
    }

    /// Move the highlighted row with wrap-around. Rows are addressed by stable
    /// id through the tree's own focus, so the keyboard path and the mouse
    /// path highlight the same element.
    fn moveContextMenuFocus(self: *App, next: bool) !void {
        const menu = self.context_menu orelse return;
        var storage: [context_menu_max_items]ContextMenuItem = undefined;
        const items = contextMenuItems(menu.has_selection, menu.linkId() != null, &storage);
        var current: ?usize = null;
        if (self.ui_tree.focusedElement()) |focused| {
            for (items, 0..) |item, index| {
                if (std.mem.eql(u8, item.id, focused.id.value)) current = index;
            }
        }
        const target = if (current) |index|
            if (next) (index + 1) % items.len else (index + items.len - 1) % items.len
        else if (next) 0 else items.len - 1;
        if (self.ui_tree.focus(.{ .value = items[target].id })) try self.refreshActiveUi();
    }

    /// Run one row: close the menu first, because every row's action composes
    /// a new frame, then dispatch the row's completed named action with the
    /// arguments or origin that action already understands.
    fn activateContextMenuItem(self: *App, activation: ui.Activation, source: inputmod.InvocationSource) !void {
        const menu = self.context_menu orelse return;
        if (!std.mem.startsWith(u8, activation.id.value, "context-menu.")) return;
        var id_storage: [palette_semantic_capacity]u8 = undefined;
        if (activation.id.value.len > id_storage.len) return;
        @memcpy(id_storage[0..activation.id.value.len], activation.id.value);
        const row_id = id_storage[0..activation.id.value.len];
        var link_storage: [terminal_link_semantic_capacity]u8 = undefined;
        const link_len = menu.link_id_len;
        @memcpy(link_storage[0..link_len], menu.link_id[0..link_len]);
        try self.closeContextMenu();

        if (std.mem.eql(u8, row_id, context_menu_split_right_item.id)) {
            const args = [_]inputmod.Argument{.{ .name = "direction", .value = "right" }};
            try self.dispatchAction(pane_split_action, .{ .source = source, .arguments = &args });
        } else if (std.mem.eql(u8, row_id, context_menu_split_down_item.id)) {
            const args = [_]inputmod.Argument{.{ .name = "direction", .value = "down" }};
            try self.dispatchAction(pane_split_action, .{ .source = source, .arguments = &args });
        } else if (std.mem.eql(u8, row_id, context_menu_open_link_item.id)) {
            if (link_len == 0) return;
            try self.dispatchAction(terminal_open_link_action, .{
                .source = source,
                .origin = .{ .value = link_storage[0..link_len] },
            });
        } else if (std.mem.eql(u8, row_id, context_menu_copy_item.id)) {
            try self.dispatchAction(clipboard_copy_action, .{ .source = source });
        } else if (std.mem.eql(u8, row_id, context_menu_paste_item.id)) {
            try self.dispatchAction(clipboard_paste_action, .{ .source = source });
        } else if (std.mem.eql(u8, row_id, context_menu_search_item.id)) {
            try self.dispatchAction(search_open_action, .{ .source = source });
        }
    }

    /// A right press on the focused terminal that the program has not captured
    /// (CONDUIT.md: Shift overrides a program's mouse capture). Returns false
    /// when the press is the program's and must become a mouse report as before.
    fn handleTerminalRightPress(self: *App, point: ui.Point, hit: *const ui.Element, mods: platform.Mods) !bool {
        if (self.presentedLive().terminal().pointerOwner(inputmod.pointerMods(mods)) == .program) return false;
        self.context_menu_pointer_owned = true;
        switch (self.right_click) {
            .paste => {
                try self.dispatchAction(clipboard_paste_action, .{ .source = .mouse });
                // A consumed UI gesture skips the per-event flush, and a paste
                // must not wait for the next unrelated event to reach the child.
                try self.flushToChild();
            },
            .menu => {
                const cell = self.fonts.metrics().cell;
                const col: u32 = if (point.x <= 0) 0 else @as(u32, @intCast(point.x)) / cell.width_px;
                const row: u32 = if (point.y <= 0) 0 else @as(u32, @intCast(point.y)) / cell.height_px;
                const link_id: ?[]const u8 = if (isTerminalLink(hit)) hit.id.value else null;
                try self.openContextMenu(col, row, link_id);
            },
        }
        return true;
    }

    /// The context menu is modal like the palette: pointer gestures inside it
    /// focus or activate its own rows, a press outside closes it, and every
    /// gesture is owned through release so nothing underneath fires.
    fn handleContextMenuUiEvent(self: *App, event: platform.Event) !bool {
        const tree = self.activeUiTree();
        switch (event) {
            .mouse_motion => |motion| {
                const point = devicePointerPoint(motion.x, motion.y, self.window.state.scale);
                const before = uiInteractionState(tree);
                tree.pointerMoved(point);
                if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                return true;
            },
            .mouse_button => |button| {
                const point = devicePointerPoint(button.x, button.y, self.window.state.scale);
                const bounds = self.contextMenuBoundsNow();
                const inside = bounds != null and self.pointInCellRect(point, bounds.?);
                switch (button.action) {
                    .press => {
                        self.context_menu_pointer_owned = true;
                        if (!inside) {
                            try self.closeContextMenu();
                            return true;
                        }
                        if (button.button != .left) return true;
                        const before = uiInteractionState(tree);
                        tree.pointerPressed(point);
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        return true;
                    },
                    .repeat => return true,
                    .release => {
                        if (!self.context_menu_pointer_owned) return true;
                        self.context_menu_pointer_owned = false;
                        if (button.button != .left) return true;
                        const before = uiInteractionState(tree);
                        const activation = tree.pointerReleased(point);
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        if (activation) |requested| try self.activateContextMenuItem(requested, .mouse);
                        return true;
                    },
                }
            },
            .wheel => return true,
            .text_input, .key => return false,
            .text_editing, .candidates => return true,
            else => return false,
        }
    }

    fn paletteBounds(self: *const App) ?ui.Rect {
        if (!self.paletteVisible()) return null;
        const canvas = self.ui_canvas.bounds();
        if (canvas.width < 20 or canvas.height < 5) return null;
        const width = @min(@as(u32, 64), canvas.width - 4);
        const wanted_height: u32 = switch (self.palette_step) {
            .closed => return null,
            .commands => @intCast(@min(self.palette_model.results().len, palette_visible_rows) + 4),
            .input => 5,
            .choices => |step| blk: {
                const definition = self.actions.definitions()[step.definition_index];
                const values = switch (definition.palette.?.argument) {
                    .choices => |choice_argument| choice_argument.values,
                    else => return null,
                };
                break :blk @intCast(@min(values.len, palette_visible_rows) + 4);
            },
        };
        const height = @min(wanted_height, canvas.height - 2);
        if (width < 16 or height < 4) return null;
        return .{
            .x = (canvas.width - width) / 2,
            .y = (canvas.height - height) / 2,
            .width = width,
            .height = height,
        };
    }

    fn paletteResultStart(self: *const App, visible_count: usize) usize {
        const selected = self.palette_model.selectedResultIndex() orelse return 0;
        if (selected < visible_count) return 0;
        return selected - visible_count + 1;
    }

    fn composePalettePreedit(
        self: *App,
        parent: ui.Id,
        field_bounds: ui.Rect,
        field: *const ui.Input,
    ) !void {
        const text = self.composition.preedit();
        if (text.len == 0 or !std.unicode.utf8ValidateSlice(text) or field_bounds.width == 0) return;
        const prefix_cells = preeditCellWidth(field.text()[0..field.cursorByte()]) orelse 0;
        const start_x = field_bounds.x + @min(prefix_cells, field_bounds.width - 1);
        const normal: ui.TextStyle = .{ .foreground = .foreground, .underline = .accent };
        const selected: ui.TextStyle = .{
            .foreground = .bright_white,
            .background = .selection,
            .underline = .accent,
        };
        const selection = self.composition.selection();
        const start = @min(@as(usize, selection.start), text.len);
        const end = @min(start +| @as(usize, selection.length), text.len);
        var runs: [3]ui.Run = undefined;
        var run_count: usize = 0;
        if (selection.length != 0 and utf8Boundary(text, start) and utf8Boundary(text, end)) {
            if (start != 0) {
                runs[run_count] = .{ .text = text[0..start], .style = normal };
                run_count += 1;
            }
            runs[run_count] = .{ .text = text[start..end], .style = selected };
            run_count += 1;
            if (end != text.len) {
                runs[run_count] = .{ .text = text[end..], .style = normal };
                run_count += 1;
            }
        } else {
            runs[0] = .{ .text = text, .style = normal };
            run_count = 1;
        }
        try self.ui_tree.addText(.{
            .id = .{ .value = "palette.preedit" },
            .parent = parent,
            .role = "preedit",
            .label = text,
            .bounds = .{
                .x = start_x,
                .y = field_bounds.y,
                .width = field_bounds.right() - start_x,
                .height = 1,
            },
        }, .{ .runs = runs[0..run_count] });
    }

    fn composePalette(self: *App) !void {
        const bounds = self.paletteBounds() orelse return;
        const dialog_id: ui.Id = .{ .value = "palette.dialog" };
        try self.ui_tree.addSurface(.{
            .id = dialog_id,
            .role = "dialog",
            .label = "Command palette",
            .bounds = bounds,
        }, .{
            .rect = bounds,
            .erase_underlay = true,
            .fill = .background,
            .border = .double,
            .border_style = .{ .foreground = .bright_blue, .background = .background },
            .title = " Command palette ",
            .title_style = .{ .foreground = .bright_white, .background = .background, .face_style = .bold },
        });

        const inner_x = bounds.x + 2;
        const inner_width = bounds.width - 4;
        switch (self.palette_step) {
            .closed => {},
            .commands => {
                const field_bounds: ui.Rect = .{
                    .x = inner_x,
                    .y = bounds.y + 1,
                    .width = inner_width,
                    .height = 1,
                };
                try self.ui_tree.addInput(.{
                    .id = .{ .value = "palette.query" },
                    .parent = dialog_id,
                    .role = "input",
                    .label = "Filter commands",
                    .action = palette_activate_action,
                    .bounds = field_bounds,
                }, &self.palette_query, .{
                    .text = .{ .foreground = .bright_white, .background = .black },
                    .selection_background = .selection,
                    .cursor_background = .accent,
                    .cursor_foreground = .background,
                });
                try self.composePalettePreedit(dialog_id, field_bounds, &self.palette_query);

                const visible_count = @min(self.palette_model.results().len, palette_visible_rows);
                if (visible_count == 0) {
                    const runs = [_]ui.Run{.{
                        .text = "No matching commands",
                        .style = .{ .foreground = .bright_black },
                    }};
                    try self.ui_tree.addText(.{
                        .id = .{ .value = "palette.empty" },
                        .parent = dialog_id,
                        .role = "status",
                        .label = "No matching commands",
                        .bounds = .{ .x = inner_x, .y = bounds.y + 2, .width = inner_width, .height = 1 },
                    }, .{ .runs = &runs });
                    return;
                }

                const start = self.paletteResultStart(visible_count);
                const selected = self.palette_model.selectedDefinitionIndex();
                for (self.palette_model.results()[start .. start + visible_count], 0..) |definition_index, row| {
                    if (definition_index >= self.palette_row_ids.len) continue;
                    const definition = &self.actions.definitions()[definition_index];
                    const id_text = try std.fmt.bufPrint(
                        &self.palette_row_ids[definition_index],
                        "palette.action.{d}",
                        .{definition_index},
                    );
                    var chord_storage: [96]u8 = undefined;
                    const chords = palette_mod.formatActionBindings(
                        &chord_storage,
                        definition.name,
                        self.bindings,
                        self.binding_profile,
                    );
                    const label = if (chords.text.len == 0)
                        try std.fmt.bufPrint(&self.palette_row_labels[definition_index], "{s}", .{definition.label})
                    else
                        try std.fmt.bufPrint(
                            &self.palette_row_labels[definition_index],
                            "{s}  {s}{s}",
                            .{ definition.label, chords.text, if (chords.truncated) " …" else "" },
                        );
                    const is_selected = selected != null and selected.? == definition_index;
                    const id: ui.Id = .{ .value = id_text };
                    try self.ui_tree.addInteractiveText(.{
                        .id = id,
                        .parent = dialog_id,
                        .role = "command",
                        .label = label,
                        .selected = is_selected,
                        .action = palette_activate_action,
                        .bounds = .{
                            .x = inner_x,
                            .y = bounds.y + 2 + @as(u32, @intCast(row)),
                            .width = inner_width,
                            .height = 1,
                        },
                    }, .{
                        .id = id,
                        .label = label,
                        .action = palette_activate_action,
                        .normal = if (is_selected)
                            .{ .foreground = .bright_white, .background = .selection }
                        else
                            .{ .foreground = .foreground },
                        .hovered = .{ .foreground = .bright_white, .underline = .accent },
                        .focused = .{ .foreground = .black, .background = .accent },
                    });
                }
            },
            .input => |definition_index| {
                const definition = &self.actions.definitions()[definition_index];
                const palette_argument_meta = switch (definition.palette.?.argument) {
                    .input => |value| value,
                    else => return,
                };
                const runs = [_]ui.Run{.{
                    .text = palette_argument_meta.prompt,
                    .style = .{ .foreground = .bright_white },
                }};
                try self.ui_tree.addText(.{
                    .id = .{ .value = "palette.prompt" },
                    .parent = dialog_id,
                    .role = "prompt",
                    .label = palette_argument_meta.prompt,
                    .bounds = .{ .x = inner_x, .y = bounds.y + 1, .width = inner_width, .height = 1 },
                }, .{ .runs = &runs });
                const field_bounds: ui.Rect = .{
                    .x = inner_x,
                    .y = bounds.y + 2,
                    .width = inner_width,
                    .height = 1,
                };
                try self.ui_tree.addInput(.{
                    .id = .{ .value = "palette.argument" },
                    .parent = dialog_id,
                    .role = "input",
                    .label = palette_argument_meta.prompt,
                    .action = palette_activate_action,
                    .bounds = field_bounds,
                }, &self.palette_argument, .{
                    .text = .{ .foreground = .bright_white, .background = .black },
                    .selection_background = .selection,
                    .cursor_background = .accent,
                    .cursor_foreground = .background,
                });
                try self.composePalettePreedit(dialog_id, field_bounds, &self.palette_argument);
            },
            .choices => |step| {
                const definition = &self.actions.definitions()[step.definition_index];
                const palette_argument_meta = switch (definition.palette.?.argument) {
                    .choices => |value| value,
                    else => return,
                };
                const runs = [_]ui.Run{.{
                    .text = palette_argument_meta.prompt,
                    .style = .{ .foreground = .bright_white },
                }};
                try self.ui_tree.addText(.{
                    .id = .{ .value = "palette.prompt" },
                    .parent = dialog_id,
                    .role = "prompt",
                    .label = palette_argument_meta.prompt,
                    .bounds = .{ .x = inner_x, .y = bounds.y + 1, .width = inner_width, .height = 1 },
                }, .{ .runs = &runs });
                const visible_count = @min(palette_argument_meta.values.len, palette_visible_rows);
                const start = if (step.selected < visible_count) 0 else step.selected - visible_count + 1;
                for (palette_argument_meta.values[start .. start + visible_count], 0..) |choice, row| {
                    const choice_index = start + row;
                    if (step.definition_index >= self.palette_choice_ids.len or
                        choice_index >= self.palette_choice_ids[step.definition_index].len) break;
                    const id_text = try std.fmt.bufPrint(
                        &self.palette_choice_ids[step.definition_index][choice_index],
                        "palette.choice.{d}.{d}",
                        .{ step.definition_index, choice_index },
                    );
                    const is_selected = choice_index == step.selected;
                    const id: ui.Id = .{ .value = id_text };
                    try self.ui_tree.addInteractiveText(.{
                        .id = id,
                        .parent = dialog_id,
                        .role = "choice",
                        .label = choice.label,
                        .selected = is_selected,
                        .action = palette_activate_action,
                        .bounds = .{
                            .x = inner_x,
                            .y = bounds.y + 2 + @as(u32, @intCast(row)),
                            .width = inner_width,
                            .height = 1,
                        },
                    }, .{
                        .id = id,
                        .label = choice.label,
                        .action = palette_activate_action,
                        .normal = if (is_selected)
                            .{ .foreground = .bright_white, .background = .selection }
                        else
                            .{ .foreground = .foreground },
                        .hovered = .{ .foreground = .bright_white, .underline = .accent },
                        .focused = .{ .foreground = .black, .background = .accent },
                    });
                }
            },
        }
    }

    fn presentedSessionId(self: *const App) session.SessionId {
        return if (self.scratchpadVisible()) self.activeWorkspaceConst().scratchpadId() else self.activePresentationConst().active_session_id;
    }

    fn presentedLive(self: *App) *session.Session {
        if (self.scratchpadVisible()) return self.scratchpadLive() orelse self.activeLive();
        return self.activeLive();
    }

    fn presentedLiveConst(self: *const App) *const session.Session {
        if (self.scratchpadVisible()) return self.scratchpadLiveConst() orelse self.activeLiveConst();
        return self.activeLiveConst();
    }

    fn presentedCellRect(self: *const App) ?ui.Rect {
        if (self.scratchpadVisible()) return self.scratchpadInnerRect();
        if (self.focusedPaneLayout()) |layout| return .{
            .x = layout.rect.col,
            .y = layout.rect.row,
            .width = layout.rect.cols,
            .height = layout.rect.rows,
        };
        return null;
    }

    fn sidebarOriginColumns(self: *const App) u16 {
        const bounds = self.ui_canvas.bounds();
        return sidebarColumns(@intCast(bounds.width), self.sidebar_width_cols, self.sidebar_visible);
    }

    fn uiGeometry(self: *const App) ui.Geometry {
        const cell = self.fonts.metrics().cell;
        return .{
            .cell_width = cell.width_px,
            .cell_height = cell.height_px,
            .surface_bounds = .{
                .x = 0,
                .y = 0,
                .width = self.size.width,
                .height = self.size.height,
            },
        };
    }

    /// Start native text input once the terminal has a cursor, and keep the
    /// input method's candidate window anchored to that cursor.
    ///
    /// Font metrics are device pixels while SDL's input rectangle is logical
    /// pixels. A valid selection start has the same grapheme measurement as
    /// the rendered preedit, so the candidate window follows that caret; an
    /// invalid external offset safely falls back to the leading edge.
    fn syncTextInput(self: *App) !void {
        const physical = self.fonts.metrics().cell;
        const scale = self.window.state.scale;
        if (self.activeUiTree().focusedInput()) |field| {
            const element = self.activeUiTree().focusedElement() orelse return;
            if (element.bounds.x < 0 or element.bounds.y < 0) return;
            const field_col: u32 = @intCast(@divFloor(element.bounds.x, @as(i32, @intCast(physical.width_px))));
            const field_row: u32 = @intCast(@divFloor(element.bounds.y, @as(i32, @intCast(physical.height_px))));
            const field_cols = @max(@as(u32, 1), element.bounds.width / physical.width_px);
            const text_prefix = field.text()[0..field.cursorByte()];
            const text_cells = preeditCellWidth(text_prefix) orelse 0;
            const selection = self.composition.selection();
            const preedit_prefix_len = @min(@as(usize, selection.start), selection.text.len);
            const preedit_cells = if (utf8Boundary(selection.text, preedit_prefix_len))
                preeditCellWidth(selection.text[0..preedit_prefix_len]) orelse 0
            else
                0;
            try self.window.startTextInput();
            try self.window.pointTextInputAt(
                field_col + @min(text_cells +| preedit_cells, field_cols - 1),
                field_row,
                .{
                    .width = logicalPixels(physical.width_px, scale),
                    .height = logicalPixels(physical.height_px, scale),
                },
                0,
            );
            return;
        }

        const presented = self.presentedLive();
        const cursor = presented.terminal().cursor().position orelse return;
        const grid = presented.terminal().gridSize();
        const rect = self.presentedCellRect() orelse return;
        const selection = self.composition.selection();
        const prefix_len = @min(@as(usize, selection.start), selection.text.len);
        const caret_cells = if (utf8Boundary(selection.text, prefix_len))
            preeditCellWidth(selection.text[0..prefix_len]) orelse 0
        else
            0;
        const caret_col = @min(
            @as(u32, cursor.col) +| caret_cells,
            @as(u32, grid.cols - 1),
        ) + rect.x;
        const caret_row = @as(u32, cursor.row) + rect.y;

        try self.window.startTextInput();
        try self.window.pointTextInputAt(
            caret_col,
            caret_row,
            .{
                .width = logicalPixels(physical.width_px, scale),
                .height = logicalPixels(physical.height_px, scale),
            },
            0,
        );
    }

    fn sameTerminalHyperlink(a: ?term.Hyperlink, b: ?term.Hyperlink) bool {
        if (a == null or b == null) return a == null and b == null;
        return switch (a.?) {
            .invalid_utf8 => switch (b.?) {
                .invalid_utf8 => true,
                .uri => false,
            },
            .uri => |left| switch (b.?) {
                .invalid_utf8 => false,
                .uri => |right| std.mem.eql(u8, left, right),
            },
        };
    }

    fn terminalHyperlinkUri(value: term.Hyperlink) []const u8 {
        return switch (value) {
            .uri => |uri| uri,
            // The detector treats every supplied range as authoritative even
            // when this deliberately non-URL target cannot be emitted.
            .invalid_utf8 => "",
        };
    }

    fn appendTerminalLinkScalar(self: *App, length: *usize, codepoint: u21) bool {
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(codepoint, &encoded) catch return false;
        if (count > self.terminal_link_row.len - length.*) return false;
        @memcpy(self.terminal_link_row[length.* .. length.* + count], encoded[0..count]);
        length.* += count;
        return true;
    }

    fn appendTerminalLinkCell(self: *App, length: *usize, cell: term.Cell) bool {
        if (cell.wide_tail) return true;
        if (cell.codepoint == 0) {
            if (length.* == self.terminal_link_row.len) return false;
            self.terminal_link_row[length.*] = ' ';
            length.* += 1;
        } else if (!self.appendTerminalLinkScalar(length, cell.codepoint)) return false;
        for (cell.grapheme) |codepoint| {
            if (!self.appendTerminalLinkScalar(length, codepoint)) return false;
        }
        return true;
    }

    fn terminalLinkCellByteLen(cell: term.Cell) ?usize {
        if (cell.wide_tail) return 0;
        var length: usize = if (cell.codepoint == 0) 1 else 0;
        if (cell.codepoint != 0) {
            var encoded: [4]u8 = undefined;
            length = std.unicode.utf8Encode(cell.codepoint, &encoded) catch return null;
        }
        for (cell.grapheme) |codepoint| {
            var encoded: [4]u8 = undefined;
            length += std.unicode.utf8Encode(codepoint, &encoded) catch return null;
        }
        return length;
    }

    fn terminalLinkCellBounds(
        terminal: *const term.Terminal,
        row: u16,
        span: link.Span,
    ) ?TerminalLinkCellBounds {
        var byte_offset: usize = 0;
        var start_col: ?u16 = null;
        var col: u16 = 0;
        while (col < terminal.gridSize().cols) : (col += 1) {
            const cell = terminal.cell(.{ .col = col, .row = row }) orelse return null;
            if (cell.wide_tail) continue;
            const byte_len = terminalLinkCellByteLen(cell) orelse return null;
            const next_offset = byte_offset + byte_len;
            if (span.start == byte_offset) start_col = col;
            if ((span.start > byte_offset and span.start < next_offset) or
                (span.end > byte_offset and span.end < next_offset)) return null;
            if (span.end == next_offset) {
                const first = start_col orelse return null;
                const cell_width: u32 = if (cell.wide) 2 else 1;
                const end_col = @as(u32, col) + cell_width;
                if (end_col <= @as(u32, first) or end_col > std.math.maxInt(u16)) return null;
                return .{ .col = first, .width = @intCast(end_col - @as(u32, first)) };
            }
            byte_offset = next_offset;
        }
        return null;
    }

    fn copyTerminalLinkText(self: *App, text: []const u8) ?[]const u8 {
        if (text.len > self.terminal_link_text.len - self.terminal_link_text_len) return null;
        const start = self.terminal_link_text_len;
        const end = start + text.len;
        @memcpy(self.terminal_link_text[start..end], text);
        self.terminal_link_text_len = end;
        return self.terminal_link_text[start..end];
    }

    fn appendTerminalLinkRange(
        self: *App,
        count: *usize,
        overflow: *bool,
        start: usize,
        end: usize,
        hyperlink: term.Hyperlink,
    ) void {
        if (start >= end or overflow.*) return;
        if (count.* == self.terminal_link_ranges.len) {
            overflow.* = true;
            return;
        }
        self.terminal_link_ranges[count.*] = .{
            .span = .{ .start = start, .end = end },
            .uri = terminalHyperlinkUri(hyperlink),
        };
        count.* += 1;
    }

    fn composeTerminalLinkRow(
        self: *App,
        terminal: *const term.Terminal,
        session_id: session.SessionId,
        parent: ui.Id,
        terminal_rect: ui.Rect,
        row: u16,
    ) !void {
        if (self.terminal_link_target_count == self.terminal_link_targets.len) return;

        var row_len: usize = 0;
        var range_count: usize = 0;
        var range_overflow = false;
        var active_hyperlink: ?term.Hyperlink = null;
        var active_start: usize = 0;
        var col: u16 = 0;
        while (col < terminal.gridSize().cols) : (col += 1) {
            const position = term.Position{ .col = col, .row = row };
            const cell = terminal.cell(position) orelse return;
            if (cell.wide_tail) continue;
            const hyperlink = terminal.hyperlink(position);
            if (!sameTerminalHyperlink(active_hyperlink, hyperlink)) {
                if (active_hyperlink) |previous| {
                    self.appendTerminalLinkRange(
                        &range_count,
                        &range_overflow,
                        active_start,
                        row_len,
                        previous,
                    );
                }
                active_hyperlink = hyperlink;
                active_start = row_len;
            }
            if (!self.appendTerminalLinkCell(&row_len, cell)) return;
        }
        if (active_hyperlink) |previous| {
            self.appendTerminalLinkRange(
                &range_count,
                &range_overflow,
                active_start,
                row_len,
                previous,
            );
        }
        if (row_len == 0) return;
        if (range_overflow) {
            self.terminal_link_ranges[0] = .{
                .span = .{ .start = 0, .end = row_len },
                .uri = "",
            };
            range_count = 1;
        }

        const detected = link.detectRow(
            self.terminal_link_row[0..row_len],
            self.terminal_link_ranges[0..range_count],
            &self.terminal_link_matches,
            .{},
        ) catch return;
        for (detected.matches) |match| {
            const kind: TerminalLinkTargetKind = switch (match.target) {
                .url => .url,
                .file => .file,
            };
            const target_text = switch (match.target) {
                .url => |value| value,
                .file => |file| file.path,
            };
            const line: ?u32 = switch (match.target) {
                .url => null,
                .file => |file| file.line,
            };
            const column: ?u32 = switch (match.target) {
                .url => null,
                .file => |file| file.column,
            };
            if (self.terminal_link_target_count == self.terminal_link_targets.len) return;
            const bounds = terminalLinkCellBounds(terminal, row, match.span) orelse continue;
            if (match.text.len + target_text.len > self.terminal_link_text.len - self.terminal_link_text_len) return;
            const copied_label = self.copyTerminalLinkText(match.text) orelse return;
            const copied_url = self.copyTerminalLinkText(target_text) orelse return;
            const target_index = self.terminal_link_target_count;
            const fingerprint = terminalLinkFingerprint(kind, copied_url, line, column);
            const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
            const semantic = std.fmt.bufPrint(
                &self.terminal_link_ids[self.terminal_link_id_generation][target_index],
                "workspace.{d}.session.{d}.terminal-link.{d}.{d}.{s}.{d}",
                .{
                    @intFromEnum(self.activePresentation().key),
                    @intFromEnum(session_id),
                    row,
                    bounds.col,
                    fingerprint_hex[0..],
                    copied_url.len,
                },
            ) catch return;
            const id: ui.Id = .{ .value = semantic };
            self.terminal_link_targets[target_index] = .{
                .id = semantic,
                .kind = kind,
                .target = copied_url,
                .line = line,
                .column = column,
                .session_id = session_id,
            };
            self.terminal_link_target_count += 1;
            try self.ui_tree.addInteractiveText(.{
                .id = id,
                .parent = parent,
                .role = "terminal_link",
                .label = copied_label,
                .action = terminal_open_link_action,
                .bounds = .{
                    .x = terminal_rect.x + @as(u32, bounds.col),
                    .y = terminal_rect.y + @as(u32, row),
                    .width = @as(u32, bounds.width),
                    .height = 1,
                },
            }, .{
                .id = id,
                .label = copied_label,
                .action = terminal_open_link_action,
                .paint = .decorations_only,
                .normal = .{},
                .hovered = if (self.terminal_link_modifier) .{ .underline = .accent } else .{},
                .focused = .{ .underline = .accent },
            });
        }
    }

    fn composeTerminalLinks(
        self: *App,
        terminal: *const term.Terminal,
        session_id: session.SessionId,
        parent: ui.Id,
        terminal_rect: ui.Rect,
    ) !void {
        var row: u16 = 0;
        while (row < terminal.gridSize().rows) : (row += 1) {
            try self.composeTerminalLinkRow(terminal, session_id, parent, terminal_rect, row);
            if (self.terminal_link_target_count == self.terminal_link_targets.len) return;
        }
    }

    fn terminalLinkTarget(self: *const App, id: []const u8) ?TerminalLinkTarget {
        for (self.terminal_link_targets[0..self.terminal_link_target_count]) |target| {
            if (std.mem.eql(u8, target.id, id)) return target;
        }
        return null;
    }

    fn searchBarLayout(self: *const App) ?SearchBarLayout {
        if (!self.search_visible) return null;
        return calculateSearchBarLayout(self.ui_canvas.bounds());
    }

    fn searchStatusText(self: *App) []const u8 {
        const text = if (self.search_failure) |failure|
            std.fmt.bufPrint(&self.search_control_label, "{s}", .{failure}) catch "search error"
        else if (self.search_query.text().len == 0)
            std.fmt.bufPrint(&self.search_control_label, "type to search", .{}) catch "search"
        else if (searchVisibleProgress(self.search_progress, self.search_page_scan != null) == .running)
            std.fmt.bufPrint(&self.search_control_label, "{d}{s} searching...", .{
                self.search_match_count,
                if (self.search_truncated) "+" else "",
            }) catch "searching..."
        else if (self.search_progress == .scratch_exhausted)
            std.fmt.bufPrint(&self.search_control_label, "search storage exhausted", .{}) catch "search error"
        else if (self.search_match_count == 0)
            std.fmt.bufPrint(&self.search_control_label, "no matches", .{}) catch "none"
        else
            std.fmt.bufPrint(&self.search_control_label, "{d}/{d}{s}", .{
                self.search_active_index + 1,
                self.search_match_count,
                if (self.search_truncated) "+" else "",
            }) catch "matches";
        return text;
    }

    fn composeSearchHighlights(self: *App) !void {
        if (!self.search_visible or self.search_match_count == 0) return;
        const rect = self.presentedCellRect() orelse return;
        const terminal = self.presentedLive().terminalConst();
        const viewport = terminal.viewport();
        if (viewport.view_rows == 0) return;
        const top = viewport.history_rows - viewport.offset;
        const bottom = top + viewport.view_rows - 1;
        const cols = terminal.gridSize().cols;
        if (cols == 0) return;

        var semantic_index: usize = 0;
        for (self.search_pages[self.search_page_slot][0..self.search_match_count], 0..) |located, match_index| {
            const match = located.match;
            const first_row: usize = match.first.row;
            const last_row: usize = match.last.row;
            if (first_row > last_row or last_row < top or first_row > bottom) continue;
            var row = @max(first_row, top);
            const final_row = @min(last_row, bottom);
            while (row <= final_row and semantic_index < self.search_highlight_ids[0].len) : (row += 1) {
                const first_col: u16 = if (row == first_row) match.first.col else 0;
                const last_col: u16 = if (row == last_row) match.last.col else cols - 1;
                if (first_col >= cols or last_col < first_col) continue;
                const clipped_last = @min(last_col, cols - 1);
                const id_text = try std.fmt.bufPrint(
                    &self.search_highlight_ids[self.search_highlight_id_generation][semantic_index],
                    "search.match.{d}.{d}",
                    .{ match_index, row },
                );
                semantic_index += 1;
                const id: ui.Id = .{ .value = id_text };
                const active = match_index == self.search_active_index;
                const bounds: ui.Rect = .{
                    .x = rect.x + @as(u32, first_col),
                    .y = rect.y + @as(u32, @intCast(row - top)),
                    .width = @as(u32, clipped_last - first_col) + 1,
                    .height = 1,
                };
                try self.ui_tree.addInteractiveText(.{
                    .id = id,
                    .role = "search_match",
                    .label = "Search match",
                    .selected = active,
                    .action = search_activate_match_action,
                    .bounds = bounds,
                }, .{
                    .id = id,
                    .label = "Search match",
                    .action = search_activate_match_action,
                    .paint = .decorations_only,
                    .normal = if (active)
                        .{ .underline = .accent, .overline = .accent }
                    else
                        .{ .underline = .bright_yellow },
                    .hovered = .{ .underline = .bright_white, .overline = .bright_white },
                    .focused = .{ .underline = .accent, .overline = .accent },
                });
            }
        }
    }

    fn composeSearchBar(self: *App) !void {
        const layout = self.searchBarLayout() orelse return;
        const bounds = layout.bounds;
        const dialog_id: ui.Id = .{ .value = "search.dialog" };
        try self.ui_tree.addSurface(.{
            .id = dialog_id,
            .role = "dialog",
            .label = "Find in scrollback",
            .bounds = bounds,
        }, .{
            .rect = bounds,
            .fill = .background,
            .border = if (layout.bordered) .single else .none,
            .border_style = .{ .foreground = .bright_blue, .background = .background },
            .title = if (layout.bordered) " Find in scrollback " else null,
            .title_style = .{ .foreground = .bright_white, .background = .background, .face_style = .bold },
        });

        const query_bounds = layout.query;
        try self.ui_tree.addInput(.{
            .id = .{ .value = "search.query" },
            .parent = dialog_id,
            .role = "input",
            .label = "Search query",
            .action = search_next_action,
            .bounds = query_bounds,
        }, &self.search_query, .{
            .text = .{ .foreground = .bright_white, .background = .black },
            .selection_background = .selection,
            .cursor_background = .accent,
            .cursor_foreground = .background,
        });
        try self.composePalettePreedit(dialog_id, query_bounds, &self.search_query);

        const detail_bounds = layout.detail orelse return;
        const status = self.searchStatusText();
        const SearchControl = struct {
            id: []const u8,
            label: []const u8,
            action: []const u8,
            width: u32,
        };
        const full_controls = [_]SearchControl{
            .{ .id = "search.previous", .label = "prev", .action = search_previous_action, .width = 4 },
            .{ .id = "search.next", .label = "next", .action = search_next_action, .width = 4 },
            .{ .id = "search.case", .label = if (self.search_case == .sensitive) "case:Aa" else "case:aa", .action = search_case_action, .width = 7 },
            .{ .id = "search.regex", .label = if (self.search_mode == .literal) "regex:off" else "regex:on", .action = search_regex_action, .width = 9 },
            .{ .id = "search.close", .label = "close", .action = search_close_action, .width = 5 },
        };
        const navigation_controls = [_]SearchControl{
            .{ .id = "search.previous", .label = "prev", .action = search_previous_action, .width = 4 },
            .{ .id = "search.next", .label = "next", .action = search_next_action, .width = 4 },
            .{ .id = "search.close", .label = "close", .action = search_close_action, .width = 5 },
        };
        const glyph_controls = [_]SearchControl{
            .{ .id = "search.previous", .label = "‹ previous", .action = search_previous_action, .width = 1 },
            .{ .id = "search.next", .label = "› next", .action = search_next_action, .width = 1 },
            .{ .id = "search.close", .label = "× close", .action = search_close_action, .width = 1 },
        };
        const no_controls = [_]SearchControl{};
        const controls: []const SearchControl = if (detail_bounds.width >= 35)
            &full_controls
        else if (detail_bounds.width >= 17)
            &navigation_controls
        else if (detail_bounds.width >= 7)
            &glyph_controls
        else
            &no_controls;

        var controls_width: u32 = 0;
        for (controls, 0..) |control, index| {
            controls_width += control.width;
            if (index != 0) controls_width += 1;
        }
        const status_width = detail_bounds.width -| controls_width -| @intFromBool(controls.len != 0);
        const runs = [_]ui.Run{.{
            .text = status,
            .style = .{ .foreground = if (self.search_failure == null) .bright_black else .bright_yellow },
        }};
        try self.ui_tree.addText(.{
            .id = .{ .value = "search.status" },
            .parent = dialog_id,
            .role = "status",
            .label = status,
            .bounds = .{ .x = detail_bounds.x, .y = detail_bounds.y, .width = status_width, .height = 1 },
        }, .{ .runs = &runs });

        var control_x = detail_bounds.right() - controls_width;
        for (controls) |control| {
            const id: ui.Id = .{ .value = control.id };
            try self.ui_tree.addInteractiveText(.{
                .id = id,
                .parent = dialog_id,
                .role = "search_control",
                .label = control.label,
                .action = control.action,
                .bounds = .{ .x = control_x, .y = detail_bounds.y, .width = control.width, .height = 1 },
            }, .{
                .id = id,
                .label = control.label,
                .action = control.action,
                .normal = .{ .foreground = .bright_black, .background = .background },
                .hovered = .{ .foreground = .bright_white, .underline = .accent, .background = .background },
                .focused = .{ .foreground = .black, .background = .accent },
            });
            control_x += control.width + 1;
        }
    }

    /// Rebuild the production sidebar and input-method frame, then derive the
    /// full-canvas overlay from that one semantic tree. Every non-identity
    /// slice is borrowed only until `drawOverlay` returns in this frame.
    fn composeUi(self: *App) !void {
        try self.ui_tree.beginFrame(self.uiGeometry());
        self.terminal_link_id_generation = (self.terminal_link_id_generation + 1) % self.terminal_link_ids.len;
        self.search_highlight_id_generation = (self.search_highlight_id_generation + 1) % self.search_highlight_ids.len;
        self.terminal_link_target_count = 0;
        self.terminal_link_text_len = 0;
        const canvas_bounds = self.ui_canvas.bounds();
        const origin = self.sidebarOriginColumns();
        if (origin != 0) {
            const sidebar_bounds: ui.Rect = .{
                .x = 0,
                .y = 0,
                .width = origin,
                .height = canvas_bounds.height,
            };
            try self.ui_tree.addSurface(.{
                .id = .{ .value = "sidebar" },
                .role = "sidebar",
                .label = "Workspaces and tabs",
                .bounds = sidebar_bounds,
            }, .{
                .rect = sidebar_bounds,
                .fill = .background,
                .border = .single,
                .border_style = .{ .foreground = .bright_black },
            });

            const content_width: u32 = if (origin > 2) origin - 2 else 0;
            if (content_width != 0 and canvas_bounds.height > 2) {
                const footer_rows: u32 = 13;
                const list_limit = canvas_bounds.height -| (footer_rows + 1);
                const active_key = self.workspace_registry.activeKey();
                var active_workspace_semantic: ?[]const u8 = null;
                var workspace_storage_index: usize = 0;
                var tab_storage_index: usize = 0;
                var row: u32 = 1;
                var workspace_index: usize = 0;
                while (row < list_limit and workspace_index < self.workspace_registry.count()) : (workspace_index += 1) {
                    const key = self.workspace_registry.keyAt(workspace_index) orelse continue;
                    const presentation = self.presentationByKey(key) orelse continue;
                    if (presentation.closing or workspace_storage_index >= self.workspace_semantic_storage.len) continue;
                    const model = self.workspace_registry.byKey(key) orelse continue;
                    const semantic = try workspaceSemanticId(&self.workspace_semantic_storage[workspace_storage_index], key);
                    workspace_storage_index += 1;
                    const workspace_id: ui.Id = .{ .value = semantic };
                    const selected = active_key != null and active_key.? == key;
                    if (selected) active_workspace_semantic = semantic;
                    try self.ui_tree.addInteractiveText(.{
                        .id = workspace_id,
                        .parent = .{ .value = "sidebar" },
                        .role = "workspace",
                        .label = model.name(),
                        .selected = selected,
                        .action = workspace_activate_action,
                        .bounds = .{ .x = 1, .y = row, .width = content_width, .height = 1 },
                    }, .{
                        .id = workspace_id,
                        .label = model.name(),
                        .action = workspace_activate_action,
                        .normal = if (selected)
                            .{ .foreground = .bright_blue, .background = .selection }
                        else
                            .{ .foreground = .bright_blue },
                        .hovered = .{ .foreground = .bright_white, .underline = .accent },
                        .focused = .{ .foreground = .bright_white, .background = .selection },
                    });
                    row += 1;
                    if (!selected) continue;

                    var tab_index: usize = 0;
                    while (row < list_limit and tab_storage_index < self.tab_semantic_storage.len) : (row += 1) {
                        const tab = model.tabAt(tab_index) orelse break;
                        tab_index += 1;
                        const tab_semantic = try tabSemanticId(&self.tab_semantic_storage[tab_storage_index], key, tab.id());
                        tab_storage_index += 1;
                        const id: ui.Id = .{ .value = tab_semantic };
                        if (self.rename_tab_id) |rename_id| {
                            if (rename_id == tab.id()) {
                                if (self.rename_input) |*field| {
                                    const rename_semantic = try tabRenameSemanticId(&self.tab_rename_semantic_storage, key);
                                    try self.ui_tree.addInput(.{
                                        .id = .{ .value = rename_semantic },
                                        .parent = workspace_id,
                                        .role = "input",
                                        .label = "Tab name",
                                        .action = tab_rename_commit_action,
                                        .bounds = .{ .x = 2, .y = row, .width = content_width - 1, .height = 1 },
                                    }, field, .{
                                        .text = .{ .foreground = .bright_white, .background = .black },
                                        .selection_background = .selection,
                                        .cursor_background = .accent,
                                        .cursor_foreground = .background,
                                    });
                                    continue;
                                }
                            }
                        }
                        const tab_selected = model.activeTabId() == tab.id();
                        try self.ui_tree.addInteractiveText(.{
                            .id = id,
                            .parent = workspace_id,
                            .role = "tab",
                            .label = tab.displayLabel(),
                            .selected = tab_selected,
                            .action = tab_activate_action,
                            .bounds = .{ .x = 2, .y = row, .width = content_width - 1, .height = 1 },
                        }, .{
                            .id = id,
                            .label = tab.displayLabel(),
                            .action = tab_activate_action,
                            .normal = if (tab_selected)
                                .{ .foreground = .bright_white, .background = .selection }
                            else
                                .{ .foreground = .foreground },
                            .hovered = .{ .foreground = .bright_white, .underline = .accent },
                            .focused = .{ .foreground = .bright_white, .background = .selection },
                        });
                    }
                }

                if (canvas_bounds.height > footer_rows + 1) {
                    const workspace_controls = [_]struct {
                        id: []const u8,
                        label: []const u8,
                        action: []const u8,
                        row: u32,
                    }{
                        .{ .id = "workspaces.new", .label = "+ workspace", .action = workspace_create_action, .row = canvas_bounds.height - 14 },
                        .{ .id = "workspaces.rename", .label = "rename workspace", .action = workspace_rename_action, .row = canvas_bounds.height - 13 },
                        .{ .id = "workspaces.switch", .label = "switch workspace", .action = workspace_switch_action, .row = canvas_bounds.height - 12 },
                        .{ .id = "workspaces.close", .label = "close workspace", .action = workspace_close_action, .row = canvas_bounds.height - 11 },
                    };
                    for (workspace_controls) |control| {
                        const control_id: ui.Id = .{ .value = control.id };
                        try self.ui_tree.addInteractiveText(.{
                            .id = control_id,
                            .parent = .{ .value = "sidebar" },
                            .role = "workspace_action",
                            .label = control.label,
                            .action = control.action,
                            .bounds = .{ .x = 1, .y = control.row, .width = content_width, .height = 1 },
                        }, .{
                            .id = control_id,
                            .label = control.label,
                            .action = control.action,
                            .normal = .{ .foreground = .bright_black },
                            .hovered = .{ .foreground = .bright_white, .underline = .accent },
                            .focused = .{ .foreground = .black, .background = .accent },
                        });
                    }

                    const parent_id: ui.Id = .{ .value = active_workspace_semantic orelse "sidebar" };
                    const tab_controls = [_]struct {
                        id: []const u8,
                        label: []const u8,
                        action: []const u8,
                        bounds: ui.Rect,
                    }{
                        .{ .id = "tabs.new", .label = "+ new tab", .action = tab_new_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 10, .width = content_width, .height = 1 } },
                        .{ .id = "tabs.rename", .label = "rename", .action = tab_rename_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 9, .width = content_width, .height = 1 } },
                        .{ .id = "tabs.close", .label = "close", .action = tab_close_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 8, .width = content_width, .height = 1 } },
                        .{ .id = "tabs.move-up", .label = "up", .action = tab_move_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 7, .width = @min(content_width, 4), .height = 1 } },
                        .{ .id = "tabs.move-down", .label = "down", .action = tab_move_action, .bounds = .{ .x = @min(content_width, 6), .y = canvas_bounds.height - 7, .width = content_width -| @min(content_width, 6), .height = 1 } },
                    };
                    for (tab_controls) |control| {
                        if (control.bounds.width == 0) continue;
                        const control_id: ui.Id = .{ .value = control.id };
                        try self.ui_tree.addInteractiveText(.{
                            .id = control_id,
                            .parent = parent_id,
                            .role = "tab_action",
                            .label = control.label,
                            .action = control.action,
                            .bounds = control.bounds,
                        }, .{
                            .id = control_id,
                            .label = control.label,
                            .action = control.action,
                            .normal = .{ .foreground = .bright_black },
                            .hovered = .{ .foreground = .bright_white, .underline = .accent },
                            .focused = .{ .foreground = .black, .background = .accent },
                        });
                    }

                    if (self.workspace_status) |status| {
                        const runs = [_]ui.Run{.{
                            .text = status,
                            .style = .{ .foreground = .bright_yellow },
                        }};
                        try self.ui_tree.addText(.{
                            .id = .{ .value = "workspace.status" },
                            .parent = .{ .value = "sidebar" },
                            .role = "status",
                            .label = status,
                            .bounds = .{ .x = 1, .y = canvas_bounds.height - 6, .width = content_width, .height = 1 },
                        }, .{ .runs = &runs });
                    }

                    const pane_controls = [_]struct {
                        id: []const u8,
                        label: []const u8,
                        action: []const u8,
                        bounds: ui.Rect,
                    }{
                        .{ .id = "panes.split-right", .label = "split right", .action = pane_split_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 5, .width = content_width, .height = 1 } },
                        .{ .id = "panes.split-down", .label = "split down", .action = pane_split_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 4, .width = content_width, .height = 1 } },
                        .{ .id = "panes.zoom", .label = "zoom", .action = pane_zoom_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 3, .width = content_width, .height = 1 } },
                        .{ .id = "panes.close", .label = "close pane", .action = pane_close_action, .bounds = .{ .x = 1, .y = canvas_bounds.height - 2, .width = content_width, .height = 1 } },
                    };
                    for (pane_controls) |control| {
                        const control_id: ui.Id = .{ .value = control.id };
                        try self.ui_tree.addInteractiveText(.{
                            .id = control_id,
                            .parent = parent_id,
                            .role = "pane_action",
                            .label = control.label,
                            .action = control.action,
                            .bounds = control.bounds,
                        }, .{
                            .id = control_id,
                            .label = control.label,
                            .action = control.action,
                            .normal = .{ .foreground = .bright_black },
                            .hovered = .{ .foreground = .bright_white, .underline = .accent },
                            .focused = .{ .foreground = .black, .background = .accent },
                        });
                    }
                }
            }

            const divider_id: ui.Id = .{ .value = "sidebar.divider" };
            try self.ui_tree.addInteractiveText(.{
                .id = divider_id,
                .parent = .{ .value = "sidebar" },
                .role = "separator",
                .label = "",
                .action = sidebar_resize_action,
                .bounds = .{ .x = origin - 1, .y = 0, .width = 1, .height = canvas_bounds.height },
            }, .{
                .id = divider_id,
                .label = "",
                .action = sidebar_resize_action,
            });
            if (origin >= 3 and canvas_bounds.height != 0) {
                const collapse_id: ui.Id = .{ .value = "sidebar.collapse" };
                try self.ui_tree.addInteractiveText(.{
                    .id = collapse_id,
                    .parent = .{ .value = "sidebar" },
                    .role = "sidebar_toggle",
                    .label = "‹",
                    .action = sidebar_toggle_action,
                    .bounds = .{ .x = origin - 2, .y = 0, .width = 1, .height = 1 },
                }, .{
                    .id = collapse_id,
                    .label = "‹",
                    .action = sidebar_toggle_action,
                    .normal = .{ .foreground = .accent },
                    .hovered = .{ .foreground = .bright_white, .background = .selection },
                    .focused = .{ .foreground = .bright_white, .background = .selection },
                });
            }
        }

        for (self.pane_layouts[0..self.pane_layout_count], 0..) |layout, index| {
            const semantic_id = try paneSemanticId(
                &self.pane_semantic_storage[index],
                self.activePresentation().key,
                layout.pane_id,
            );
            const id: ui.Id = .{ .value = semantic_id };
            const bounds: ui.Rect = .{
                .x = layout.rect.col,
                .y = layout.rect.row,
                .width = layout.rect.cols,
                .height = layout.rect.rows,
            };
            try self.ui_tree.addInteractiveText(.{
                .id = id,
                .role = "pane",
                .label = "",
                .selected = layout.focused,
                .action = pane_activate_action,
                .bounds = bounds,
            }, .{
                .id = id,
                .label = "",
                .action = pane_activate_action,
            });
            if (self.activeWorkspace().sessionById(layout.session_id)) |live| {
                try self.composeTerminalLinks(
                    live.terminalConst(),
                    layout.session_id,
                    id,
                    bounds,
                );
            }
        }
        for (self.divider_layouts[0..self.divider_layout_count], 0..) |divider, index| {
            const semantic_id = try dividerSemanticId(
                &self.divider_semantic_storage[index],
                self.activePresentation().key,
                divider.divider_id,
            );
            const visual_id = try dividerVisualSemanticId(
                &self.divider_visual_storage[index],
                self.activePresentation().key,
                divider.divider_id,
            );
            const bounds: ui.Rect = .{
                .x = divider.rect.col,
                .y = divider.rect.row,
                .width = divider.rect.cols,
                .height = divider.rect.rows,
            };
            try self.ui_tree.addSurface(.{
                .id = .{ .value = visual_id },
                .role = "presentation",
                .label = "Pane divider",
                .bounds = bounds,
            }, .{ .rect = bounds, .fill = .bright_black });
            const id: ui.Id = .{ .value = semantic_id };
            try self.ui_tree.addInteractiveText(.{
                .id = id,
                .role = "separator",
                .label = if (divider.split == .right) "│" else "─",
                .action = pane_resize_action,
                .bounds = bounds,
            }, .{
                .id = id,
                .label = if (divider.split == .right) "│" else "─",
                .action = pane_resize_action,
                .normal = .{ .foreground = .bright_black },
                .hovered = .{ .foreground = .bright_white, .background = .selection },
                .focused = .{ .foreground = .bright_white, .background = .selection },
            });
        }

        if (self.scratchpadBounds()) |scratchpad_bounds| {
            const scratchpad_id: ui.Id = .{ .value = try scratchpadSemanticId(
                &self.scratchpad_semantic_storage[0],
                self.activePresentation().key,
                "",
            ) };
            try self.ui_tree.addSurface(.{
                .id = scratchpad_id,
                .role = "dialog",
                .label = "Scratchpad",
                .bounds = scratchpad_bounds,
            }, .{
                .rect = scratchpad_bounds,
                // The retained terminal supplies the opaque interior. Keeping
                // this transparent lets the terminal and semantic chrome stay
                // separate renderers on the shared surface. Erasing only the
                // earlier UI layer prevents sidebar glyphs from being painted
                // back over the terminal after its grid has drawn.
                .erase_underlay = true,
                .fill = null,
                .border = .single,
                .border_style = .{ .foreground = .bright_blue, .background = .background },
                .title = " Scratchpad ",
                .title_style = .{ .foreground = .bright_white, .background = .background, .face_style = .bold },
            });
            if (self.scratchpadInnerRect()) |inner| {
                const terminal_id: ui.Id = .{ .value = try scratchpadSemanticId(
                    &self.scratchpad_semantic_storage[1],
                    self.activePresentation().key,
                    "terminal",
                ) };
                try self.ui_tree.addSurface(.{
                    .id = terminal_id,
                    .parent = scratchpad_id,
                    .role = "terminal",
                    .label = "Scratchpad terminal",
                    .bounds = inner,
                }, .{ .rect = inner, .fill = null });
                if (self.scratchpadLive()) |scratchpad| {
                    try self.composeTerminalLinks(
                        scratchpad.terminalConst(),
                        self.activeWorkspace().scratchpadId(),
                        terminal_id,
                        inner,
                    );
                }
            }
            if (scratchpad_bounds.width >= 24) {
                const restart_id: ui.Id = .{ .value = try scratchpadSemanticId(
                    &self.scratchpad_semantic_storage[2],
                    self.activePresentation().key,
                    "restart",
                ) };
                try self.ui_tree.addInteractiveText(.{
                    .id = restart_id,
                    .parent = scratchpad_id,
                    .role = "action",
                    .label = "restart",
                    .action = scratchpad_restart_action,
                    .bounds = .{
                        .x = scratchpad_bounds.right() - 16,
                        .y = scratchpad_bounds.y,
                        .width = 7,
                        .height = 1,
                    },
                }, .{
                    .id = restart_id,
                    .label = "restart",
                    .action = scratchpad_restart_action,
                    .normal = .{ .foreground = .bright_black, .background = .background },
                    .hovered = .{ .foreground = .bright_white, .background = .selection },
                    .focused = .{ .foreground = .black, .background = .accent },
                });
                const hide_id: ui.Id = .{ .value = try scratchpadSemanticId(
                    &self.scratchpad_semantic_storage[3],
                    self.activePresentation().key,
                    "hide",
                ) };
                try self.ui_tree.addInteractiveText(.{
                    .id = hide_id,
                    .parent = scratchpad_id,
                    .role = "action",
                    .label = "hide",
                    .action = scratchpad_hide_action,
                    .bounds = .{
                        .x = scratchpad_bounds.right() - 7,
                        .y = scratchpad_bounds.y,
                        .width = 4,
                        .height = 1,
                    },
                }, .{
                    .id = hide_id,
                    .label = "hide",
                    .action = scratchpad_hide_action,
                    .normal = .{ .foreground = .bright_black, .background = .background },
                    .hovered = .{ .foreground = .bright_white, .background = .selection },
                    .focused = .{ .foreground = .black, .background = .accent },
                });
            }
        }

        try self.composeSearchHighlights();
        try self.composeSearchBar();

        const text = self.composition.preedit();
        if (!self.paletteVisible() and !self.search_visible and text.len != 0 and std.unicode.utf8ValidateSlice(text)) {
            if (self.presentedLive().terminal().cursor().position) |cursor| {
                if (self.presentedCellRect()) |presented_rect| {
                    const presented_right = presented_rect.right();
                    const presented_bottom = presented_rect.bottom();
                    const preedit_col = @as(u32, cursor.col) + presented_rect.x;
                    const preedit_row = @as(u32, cursor.row) + presented_rect.y;
                    if (preedit_col < presented_right and preedit_row < presented_bottom) {
                        const normal: ui.TextStyle = .{
                            .foreground = .foreground,
                            .underline = .accent,
                        };
                        const selected: ui.TextStyle = .{
                            .foreground = .bright_white,
                            .background = .selection,
                            .underline = .accent,
                        };
                        const selection = self.composition.selection();
                        const start = @min(@as(usize, selection.start), text.len);
                        const end = @min(start +| @as(usize, selection.length), text.len);
                        var runs_buffer: [3]ui.Run = undefined;
                        var run_count: usize = 0;
                        if (selection.length != 0 and utf8Boundary(text, start) and utf8Boundary(text, end)) {
                            if (start != 0) {
                                runs_buffer[run_count] = .{ .text = text[0..start], .style = normal };
                                run_count += 1;
                            }
                            runs_buffer[run_count] = .{ .text = text[start..end], .style = selected };
                            run_count += 1;
                            if (end != text.len) {
                                runs_buffer[run_count] = .{ .text = text[end..], .style = normal };
                                run_count += 1;
                            }
                        } else {
                            runs_buffer[0] = .{ .text = text, .style = normal };
                            run_count = 1;
                        }

                        try self.ui_tree.addText(.{
                            .id = .{ .value = "ime.preedit" },
                            .role = "preedit",
                            .label = text,
                            .bounds = .{
                                .x = preedit_col,
                                .y = preedit_row,
                                .width = presented_right - preedit_col,
                                .height = 1,
                            },
                        }, .{ .runs = runs_buffer[0..run_count] });
                    }
                }
            }
        }
        if (origin == 0 and self.sidebar_enabled and canvas_bounds.width != 0 and canvas_bounds.height != 0) {
            // The hidden-sidebar affordance deliberately overlaps the active
            // pane's first cell. Registering it after pane content makes only
            // that one-cell chrome win painter order and semantic hit testing;
            // every other pane-body press keeps its terminal routing behavior.
            const reveal_id: ui.Id = .{ .value = "sidebar.reveal" };
            try self.ui_tree.addInteractiveText(.{
                .id = reveal_id,
                .role = "sidebar_toggle",
                .label = "›",
                .action = sidebar_toggle_action,
                .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            }, .{
                .id = reveal_id,
                .label = "›",
                .action = sidebar_toggle_action,
                .normal = .{ .foreground = .accent },
                .hovered = .{ .foreground = .bright_white, .background = .selection },
                .focused = .{ .foreground = .bright_white, .background = .selection },
            });
        }
        if (self.paletteVisible()) try self.composePalette();
        if (self.contextMenuVisible()) try self.composeContextMenu();
        if (self.closeModalActive()) {
            const modal_width = @min(canvas_bounds.width, @as(u32, 42));
            const modal_height = @min(canvas_bounds.height, @as(u32, 7));
            if (modal_width >= 12 and modal_height >= 5) {
                const modal_bounds: ui.Rect = .{
                    .x = (canvas_bounds.width - modal_width) / 2,
                    .y = (canvas_bounds.height - modal_height) / 2,
                    .width = modal_width,
                    .height = modal_height,
                };
                const closing_pane = self.pending_close_pane != null;
                const closing_workspace = self.pending_close_workspace != null;
                const modal_id: ui.Id = .{ .value = if (closing_workspace) "workspace-close.dialog" else "tab-close.dialog" };
                const question = if (closing_workspace)
                    "Close workspace and all sessions?"
                else if (closing_pane)
                    "Close running pane?"
                else
                    "Close running tab?";
                try self.ui_tree.addSurface(.{
                    .id = modal_id,
                    .role = "dialog",
                    .label = question,
                    .bounds = modal_bounds,
                }, .{
                    .rect = modal_bounds,
                    .fill = .background,
                    .border = .double,
                    .border_style = .{ .foreground = .bright_yellow },
                    .title = if (closing_workspace) " Close workspace? " else if (closing_pane) " Close pane? " else " Close tab? ",
                    .title_style = .{ .foreground = .bright_yellow, .face_style = .bold },
                });
                const message_runs = [_]ui.Run{.{
                    .text = if (closing_workspace) "All workspace sessions will stop." else "A process is still running.",
                    .style = .{ .foreground = .bright_white },
                }};
                try self.ui_tree.addText(.{
                    .id = .{ .value = if (closing_workspace) "workspace-close.message" else "tab-close.message" },
                    .parent = modal_id,
                    .role = "text",
                    .label = if (closing_workspace) "All workspace sessions will stop." else "A process is still running.",
                    .bounds = .{ .x = modal_bounds.x + 2, .y = modal_bounds.y + 2, .width = modal_bounds.width - 4, .height = 1 },
                }, .{ .runs = &message_runs });
                const choices = [_]struct { id: []const u8, label: []const u8, action: []const u8, x: u32 }{
                    .{
                        .id = if (closing_workspace) "workspace-close.cancel" else "tab-close.cancel",
                        .label = "cancel",
                        .action = if (closing_workspace) workspace_close_cancel_action else tab_close_cancel_action,
                        .x = modal_bounds.x + 2,
                    },
                    .{
                        .id = if (closing_workspace) "workspace-close.confirm" else "tab-close.confirm",
                        .label = "close",
                        .action = if (closing_workspace) workspace_close_confirm_action else tab_close_confirm_action,
                        .x = modal_bounds.right() -| 9,
                    },
                };
                for (choices) |choice| {
                    const choice_id: ui.Id = .{ .value = choice.id };
                    try self.ui_tree.addInteractiveText(.{
                        .id = choice_id,
                        .parent = modal_id,
                        .role = "action",
                        .label = choice.label,
                        .action = choice.action,
                        .bounds = .{ .x = choice.x, .y = modal_bounds.bottom() - 2, .width = 7, .height = 1 },
                    }, .{
                        .id = choice_id,
                        .label = choice.label,
                        .action = choice.action,
                        .normal = .{ .foreground = .bright_white },
                        .hovered = .{ .foreground = .bright_yellow, .underline = .accent },
                        .focused = .{ .foreground = .black, .background = .accent },
                    });
                }
            }
        }
        try self.ui_tree.endFrame();
        try self.ui_tree.render(&self.ui_canvas);
    }

    /// Make the readback buffer big enough for the current surface.
    ///
    /// The new buffer is allocated before the old one is freed, so a failed
    /// allocation leaves the app with the buffer it already had rather than
    /// with a freed one. A buffer only ever grows: a screenshot must not
    /// allocate, and a window that shrinks does not make its buffer wrong.
    fn growReadback(self: *App) !void {
        const needed = render.readbackLen(self.size);
        if (render.captureFits(self.size, self.readback.len)) return;
        const grown = try self.allocator.alloc(u8, needed);
        self.allocator.free(self.readback);
        self.readback = grown;
    }

    /// Move bytes between the child and the terminal.
    ///
    /// Neither direction waits: the read side is another thread's queue and the
    /// write side is the terminal's own answers, both copied into buffers the
    /// app already owns. That is what lets the loop's single blocking wait
    /// inside SDL stay the only wait a frame has.
    fn pumpChild(self: *App) !void {
        const presented = self.presentedLive();
        if (presented.child() != null) {
            const got = presented.drainChildOutput(self.input);
            if (got != 0) {
                self.noteSearchTerminalChange(self.presentedSessionId());
                if (self.trace) |trace| try trace.received.appendSlice(self.allocator, self.input[0..got]);
            }
            for (presented.terminal().takeEvents()) |event| self.noteTerminalEvent(presented, event);
            try self.flushToChild();
        }

        // A view is not a scheduler. Every hidden session in every workspace
        // still receives PTY output and sends terminal protocol replies.
        const active_key = self.workspace_registry.activeKey() orelse unreachable;
        for (self.workspace_presentations.items) |presentation| {
            const model = self.workspace_registry.byKey(presentation.key) orelse continue;
            var event_context: WorkspaceEventContext = .{
                .app = self,
                .key = presentation.key,
            };
            const hidden = if (presentation.key == active_key)
                model.pumpExcept(
                    self.presentedSessionId(),
                    self.input,
                    self.output,
                    .{ .ptr = &event_context, .on_events = noteWorkspaceEvents },
                )
            else
                model.pump(
                    self.input,
                    self.output,
                    .{ .ptr = &event_context, .on_events = noteWorkspaceEvents },
                );
            if (hidden.first_error) |err| log.warn(
                "a hidden session could not write a terminal response: {s}",
                .{@errorName(err)},
            );
        }
    }

    /// Deliver events produced while the workspace services a hidden session.
    fn noteWorkspaceEvents(
        ptr: *anyopaque,
        id: session.SessionId,
        events: []const term.Event,
    ) void {
        const event_context: *WorkspaceEventContext = @ptrCast(@alignCast(ptr));
        const self = event_context.app;
        const model = self.workspace_registry.byKey(event_context.key) orelse return;
        const live = model.sessionById(id) orelse return;
        var attention_changed = model.noteBackgroundActivity(id, false);
        for (events) |event| {
            switch (event) {
                .bell => attention_changed = model.noteBackgroundActivity(id, true) or attention_changed,
                else => {},
            }
            self.noteTerminalEvent(live, event);
        }
        if (attention_changed) self.invalidateUi();
    }

    /// Say what one terminal event was, by metadata only.
    fn noteTerminalEvent(self: *App, live: *session.Session, event: term.Event) void {
        switch (event) {
            // A title is a program's idea of what the user is working on, so it
            // is untrusted text and stays at debug.
            .title => |text| log.debug("program set the title to {s}", .{text}),
            .bell => log.debug("program rang the bell", .{}),
            // A program asked for the clipboard and policy said `.ask`. M1 has no
            // prompt to answer it with, so the request is refused (the terminal
            // already replied) and only its metadata is logged — never contents.
            // Answering it needs a user gesture (CONDUIT.md §11), which is why
            // nothing here acts on it.
            .permission_request => |req| {
                if (live == self.activeLive()) {
                    if (self.trace) |trace| trace.last_permission = req;
                }
                if (req.byte_count) |count| log.info(
                    "program asked to {s} the {s} clipboard ({d} byte(s)); policy is ask and there is no prompt yet, so it was refused",
                    .{ @tagName(req.operation), @tagName(req.location), count },
                ) else log.info(
                    "program asked to {s} the {s} clipboard; policy is ask and there is no prompt yet, so it was refused",
                    .{ @tagName(req.operation), @tagName(req.location) },
                );
            },
            // The working directory a shell reported, after `term` validated it.
            // It is display data, never an action, and a path a user is in is
            // personal, so it stays at debug (CONDUIT.md §11).
            .working_directory => if (live.workingDirectory()) |dir|
                log.debug("the shell reported its working directory: {s}", .{dir})
            else
                log.debug("the shell cleared its working directory", .{}),
            .prompt => |mark| if (mark.exit_code) |code|
                log.debug("shell prompt mark {s}, exit {d}", .{ @tagName(mark.kind), code })
            else
                log.debug("shell prompt mark {s}", .{@tagName(mark.kind)}),
            .reset => log.debug("the program reset the terminal; working directory and prompt marks forgotten", .{}),
        }
    }

    /// Write everything the child is owed, from the one place that writes to it.
    ///
    /// One place and one order: the terminal's own answers first, then encoded
    /// key or mouse bytes, committed text, and finally a paste. A second write
    /// site would be two writers to one pipe, and interleaved escape sequences
    /// are a bug the program cannot reproduce. Called after every handled
    /// event as well as every frame, so borrowed committed text is consumed
    /// before the next platform event can invalidate it.
    fn flushToChild(self: *App) !void {
        const presented = self.presentedLive();
        if (presented.child() == null) {
            // Preserve the existing key/mouse and paste staging semantics while
            // a startup worker has not attached the child yet. Committed text
            // borrows the platform event and cannot outlive this call.
            _ = takeCommittedText(&self.pending_committed_text);
            return;
        }
        try self.stageChildInput();

        // The integration checks trace ordinary one-pass replies. A retained
        // reply may span two internal buffers, so only copy trace bytes when
        // the terminal queue was the complete debt before this call.
        const terminal_pending = presented.terminal().pendingResponses();
        const fresh_only = presented.pendingResponseBytes() == terminal_pending;
        const replies = try presented.flushChildResponses(self.output);
        if (fresh_only and replies.written != 0) {
            if (self.trace) |trace| {
                std.debug.assert(replies.written <= self.output.len);
                try trace.sent.appendSlice(self.allocator, self.output[0..replies.written]);
            }
        }
        if (replies.hasPending()) return;
        try self.flushStagedChildInput();
    }

    /// Copy every ephemeral or separately owned input source into one ordered
    /// queue before another platform event can invalidate committed text.
    fn stageChildInput(self: *App) !void {
        const committed = self.pending_committed_text;
        const paste_bytes = self.pending_paste orelse &.{};
        const staged = std.math.add(usize, self.child_input.len, committed.len) catch return error.OutOfMemory;
        const additional = std.math.add(usize, staged, paste_bytes.len) catch return error.OutOfMemory;
        try self.pending_child_bytes.ensureUnusedCapacity(self.allocator, additional);

        self.pending_child_bytes.appendSliceAssumeCapacity(self.child_input.slice());
        self.pending_child_bytes.appendSliceAssumeCapacity(committed);
        self.pending_child_bytes.appendSliceAssumeCapacity(paste_bytes);
        self.child_input.len = 0;
        _ = takeCommittedText(&self.pending_committed_text);
        if (self.pending_paste) |bytes| {
            self.pending_paste = null;
            self.allocator.free(bytes);
        }
    }

    /// Offer queued user bytes in order, retaining a short or zero-write tail.
    ///
    /// The child's input buffer is full when the program is not reading. The
    /// next frame retries the remainder without blocking the render thread.
    fn flushStagedChildInput(self: *App) !void {
        const child = self.presentedLive().child() orelse return;
        while (self.pending_child_offset < self.pending_child_bytes.items.len) {
            const pending = self.pending_child_bytes.items[self.pending_child_offset..];
            const took = try child.write(pending);
            if (took > pending.len) return error.SystemError;
            if (took == 0) {
                log.warn("the child took no input; {d} bytes are still owed", .{pending.len});
                return;
            }
            if (self.trace) |trace| try trace.sent.appendSlice(self.allocator, pending[0..took]);
            self.pending_child_offset += took;
        }
        self.pending_child_bytes.clearRetainingCapacity();
        self.pending_child_offset = 0;
    }

    /// Act on one wheel event, and say what happened to the log.
    ///
    /// Two possible owners, decided by the terminal rather than here: on the
    /// primary screen the viewport moves and the frame has to be redrawn, and on
    /// the alternate screen the bytes belong to the program and go out with the
    /// next `pumpChild`. Nothing is written to the child from in here, so the
    /// one write site stays the one.
    fn onWheel(self: *App, wheel: platform.Wheel) !void {
        const presented = self.presentedLive();
        const cell = self.fonts.metrics().cell;
        const origin_px = self.terminalOriginPixels();
        const origin_y_px = self.terminalOriginYPixels();
        const geometry = self.pointerGeometry();
        var terminal_wheel = wheel;
        terminal_wheel.x = clippedPaneCoordinate(
            terminal_wheel.x * self.window.state.scale.factor - @as(f32, @floatFromInt(origin_px)),
            geometry.surface_width_px,
        );
        terminal_wheel.y = clippedPaneCoordinate(
            terminal_wheel.y * self.window.state.scale.factor - @as(f32, @floatFromInt(origin_y_px)),
            geometry.surface_height_px,
        );
        const outcome = presented.terminal().scrollByWheel(
            .{
                .dy = terminal_wheel.dy,
                .precise = terminal_wheel.precise,
                .flipped = terminal_wheel.flipped,
            },
            .{
                .x = terminal_wheel.x,
                .y = terminal_wheel.y,
                .surface_width_px = geometry.surface_width_px,
                .surface_height_px = geometry.surface_height_px,
                .cell_width_px = cell.width_px,
                .cell_height_px = cell.height_px,
            },
            &self.child_input,
        );
        switch (outcome) {
            .viewport => |rows| {
                if (rows == 0) return;
                log.info("wheel: the viewport moved {d} rows, {d} above the bottom", .{
                    rows,
                    presented.terminal().viewport().offset,
                });
                self.scheduler.invalidate();
            },
            .forwarded => |sent| log.info("wheel: the program owns this one; {d} byte(s) as {s}", .{
                sent.bytes,
                @tagName(sent.reason),
            }),
        }
    }

    /// The surface and cell geometry every pointer event is measured against.
    ///
    /// Built per event rather than cached: the surface and the face both move,
    /// and a cached copy that disagreed with either would put a mouse report at
    /// a cell the pointer is not over. Six numbers per event is not a cost.
    fn terminalOriginPixels(self: *const App) u32 {
        const col = if (self.presentedCellRect()) |rect| rect.x else self.sidebarOriginColumns();
        return @as(u32, col) * self.fonts.metrics().cell.width_px;
    }

    fn terminalOriginYPixels(self: *const App) u32 {
        const row = if (self.presentedCellRect()) |rect| rect.y else 0;
        return @as(u32, row) * self.fonts.metrics().cell.height_px;
    }

    fn pointerGeometry(self: *const App) inputmod.PointerGeometry {
        const cell = self.fonts.metrics().cell;
        const rect = self.presentedCellRect();
        return .{
            .surface_width_px = if (rect) |value| value.width * cell.width_px else self.size.width -| self.terminalOriginPixels(),
            .surface_height_px = if (rect) |value| value.height * cell.height_px else self.size.height,
            .cell_width_px = cell.width_px,
            .cell_height_px = cell.height_px,
        };
    }

    fn clippedPaneCoordinate(value: f32, extent: u32) f32 {
        if (extent == 0) return 0;
        return @min(@max(value, 0), @as(f32, @floatFromInt(extent - 1)));
    }

    /// Act on one pointer button event, and say what happened to the log.
    ///
    /// The ownership decision is the terminal's, not this function's: whether a
    /// click is a mouse report or the start of a selection depends on the modes
    /// the running program has set and on whether Shift is held
    /// (`term.pointerOwner`). Bytes for a child go to `child_input` and are
    /// written by `pumpChild`, so one write site stays the one.
    fn onPointerButton(self: *App, button: platform.PointerButton) !void {
        switch (button.action) {
            .press => self.terminal_pointer_presses +|= 1,
            .repeat => {},
            .release => self.terminal_pointer_presses -|= 1,
        }
        const presented = self.presentedLive();
        const geometry = self.pointerGeometry();
        var terminal_button = button;
        terminal_button.x = clippedPaneCoordinate(
            terminal_button.x * self.window.state.scale.factor - @as(f32, @floatFromInt(self.terminalOriginPixels())),
            geometry.surface_width_px,
        );
        terminal_button.y = clippedPaneCoordinate(
            terminal_button.y * self.window.state.scale.factor - @as(f32, @floatFromInt(self.terminalOriginYPixels())),
            geometry.surface_height_px,
        );
        const event = inputmod.pointerButton(&geometry, terminal_button);
        self.last_pointer = event.pointer;
        // A middle press the user owns is a paste of the primary selection, on
        // the platforms that have one. It is the user's gesture, so it is not
        // also a mouse report; a program that captured the mouse still gets
        // its middle click, because then the press is the program's.
        if (inputmod.primaryPaste(
            button,
            presented.terminal().pointerOwner(event.mods),
            platform.primary_selection_supported,
        )) {
            self.paste(.primary);
            return;
        }
        const outcome = presented.terminal().pointerEvent(
            event,
            clickStamp(self.io),
            &self.child_input,
        );
        switch (outcome) {
            .ignored => log.debug("pointer button {s} {s}: nothing owns it", .{
                @tagName(button.action),
                @tagName(button.button),
            }),
            .selection => self.scheduler.invalidate(),
            .reported => |sent| log.info("pointer button {s} {s}: {d} byte(s) to the program", .{
                @tagName(button.action),
                @tagName(button.button),
                sent,
            }),
        }
    }

    /// Route one raw transition exactly once: shipped bindings first, then a
    /// focused semantic element, then the terminal with the resolver's exact
    /// translated press. BindingState keeps ownership through modifier-order
    /// changes, so an action fires once and its repeats/releases stay owned.
    fn onKey(self: *App, key: platform.KeyEvent) !void {
        // A UI-owned gesture keeps its release even when its press changed
        // which overlay is visible. In particular, closing the palette over
        // the scratchpad must not let the scratchpad's Escape fast path steal
        // the matching release and strand an ownership record.
        if (try self.routeOwnedUiKey(key)) return;
        if (try self.routeSearchKey(key)) return;
        if (!self.paletteVisible() and self.scratchpad_escape_owned and key.key == .escape) {
            if (key.key == .escape and key.action == .release) self.scratchpad_escape_owned = false;
            return;
        }
        if (!self.paletteVisible() and !self.closeModalActive() and self.scratchpadVisible() and key.key == .escape and
            !key.mods.ctrl and !key.mods.alt and !key.mods.shift and !key.mods.super)
        {
            if (key.action == .press) {
                self.scratchpad_escape_owned = true;
                try self.setScratchpadPresentation(.hidden);
            }
            return;
        }
        var scratch: inputmod.TextScratch = .{};
        const translated = translateAppKey(&self.composition, &scratch, key);
        const modal = self.closeModalActive();
        switch (inputmod.resolve(&self.binding_state, key, translated, self.bindings)) {
            .action => |request| {
                if (modal or self.contextMenuVisible()) return;
                if (self.search_visible) {
                    const input_clipboard = self.activeUiTree().focusedInput() != null and
                        (std.mem.eql(u8, request.action, clipboard_copy_action) or
                            std.mem.eql(u8, request.action, clipboard_paste_action));
                    if (!std.mem.eql(u8, request.action, palette_open_action) and !input_clipboard) return;
                }
                if (self.paletteVisible()) {
                    const input_clipboard = self.activeUiTree().focusedInput() != null and
                        (std.mem.eql(u8, request.action, clipboard_copy_action) or
                            std.mem.eql(u8, request.action, clipboard_paste_action));
                    if (!std.mem.eql(u8, request.action, palette_open_action) and !input_clipboard) return;
                }
                if (self.scratchpadVisible() and
                    !std.mem.eql(u8, request.action, scratchpad_toggle_50_action) and
                    !std.mem.eql(u8, request.action, scratchpad_toggle_90_action) and
                    !std.mem.eql(u8, request.action, scratchpad_restart_action) and
                    !std.mem.eql(u8, request.action, scratchpad_hide_action) and
                    !std.mem.eql(u8, request.action, palette_open_action) and
                    !std.mem.eql(u8, request.action, clipboard_copy_action) and
                    !std.mem.eql(u8, request.action, clipboard_paste_action)) return;
                var invocation = request.invocation;
                if (self.activeUiTree().focusedElement()) |element| invocation.origin = element.id;
                try self.dispatchAction(request.action, invocation);
            },
            .consumed => {},
            .terminal => |press| {
                if (try self.routeFocusedUiKey(key, translated)) return;
                if (self.paletteVisible() or self.search_visible or self.contextMenuVisible()) return;
                const presented = self.presentedLive();
                switch (inputmod.clipboardKey(key, .{
                    .has_selection = presented.terminal().hasSelection(),
                })) {
                    .copy => try self.dispatchAction(clipboard_copy_action, .{ .source = .keybinding }),
                    .copy_and_deselect => {
                        try self.dispatchAction(clipboard_copy_action, .{ .source = .keybinding });
                        presented.terminal().clearSelection();
                        self.scheduler.invalidate();
                    },
                    .paste => try self.dispatchAction(clipboard_paste_action, .{ .source = .keybinding }),
                    .swallow => {},
                    .terminal => {
                        self.trackTerminalKeyTransition(key);
                        self.terminal_key_route_count += 1;
                        if (key.action != .release) presented.terminal().userInput();
                        var encoded: term.EncodedKey = .{};
                        presented.terminal().encodeKey(press, &encoded);
                        self.stageForChild(encoded.slice());
                    },
                }
            },
        }
    }

    fn routeSearchKey(self: *App, raw: platform.KeyEvent) !bool {
        if (self.paletteVisible() or self.contextMenuVisible()) return false;
        const action = searchKeyAction(self.binding_profile, self.search_visible, raw) orelse return false;
        const identity = uiKeyIdentity(raw) orelse return true;
        if (raw.action != .press) return true;
        if (!self.ui_key_state.claim(identity, .none)) return true;
        try self.dispatchAction(action, .{ .source = .keybinding });
        return true;
    }

    fn trackTerminalKeyTransition(self: *App, key: platform.KeyEvent) void {
        const identity = uiKeyIdentity(key) orelse return;
        switch (key.action) {
            .press => _ = self.terminal_key_state.claim(identity, .none),
            .repeat => {},
            .release => if (self.terminal_key_state.indexOf(identity)) |index|
                self.terminal_key_state.release(index),
        }
    }

    fn dispatchAction(self: *App, name: []const u8, invocation: inputmod.Invocation) !void {
        // A search owns tracked page pins in the presented terminal. Any
        // unrelated command may switch or destroy that session, so release
        // the search before invoking it. Clipboard actions are edits of the
        // focused search Input and keep the search open.
        if (self.search_visible and !isSearchAction(name)) try self.closeSearch();
        try self.actions.invoke(self, name, invocation);
        if (std.mem.eql(u8, name, palette_activate_action)) return;
        _ = self.palette_model.noteUsed(name);
        self.action_dispatch_count += 1;
        self.last_dispatched_action = name;
    }

    fn terminalOpenLinkAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const origin = invocation.origin orelse return;
        const target = self.terminalLinkTarget(origin.value) orelse return;
        switch (target.kind) {
            .url => self.url_opener.open(self.allocator, target.target) catch |err| {
                log.warn("terminal URL open failed for {d} byte(s): {s}", .{ target.target.len, @errorName(err) });
                return;
            },
            .file => if (!try self.openFileReferenceTab(target)) return,
        }
        self.ui_tree.clearFocus();
        try self.refreshActiveUi();
    }

    /// Open one detected file reference in a new tab of the active workspace
    /// (decision-5): snapshot the source session's tracked cwd, build the
    /// shell-free editor argv, create the tab and spawn through the workspace
    /// `ExecutionContext`. Returns false when nothing changed. `target`
    /// borrows link storage that UI composition reuses, so every borrowed byte
    /// is copied before anything here can recompose.
    fn openFileReferenceTab(self: *App, target: TerminalLinkTarget) !bool {
        var path_storage: [link.default_max_target_bytes]u8 = undefined;
        if (target.target.len > path_storage.len) return false;
        @memcpy(path_storage[0..target.target.len], target.target);
        const path = path_storage[0..target.target.len];
        const line = target.line;
        const source_id = target.session_id;

        if (self.activePresentation().load != null) {
            log.debug("file reference ignored while another load is in flight", .{});
            return false;
        }
        const source = self.activeWorkspace().sessionById(source_id) orelse return false;
        const inherited = source.workingDirectory() orelse self.activeWorkspace().workingDirectory();
        const cwd = try self.allocator.dupe(u8, inherited);
        var cwd_owned = true;
        defer if (cwd_owned) self.allocator.free(cwd);
        const argv = buildFileReferenceArgv(self.allocator, path, line, cwd) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.UnsafePath, error.PathTooLong => {
                log.debug("file reference of {d} byte(s) was not opened: {s}", .{ path.len, @errorName(err) });
                return false;
            },
        };
        var argv_owned = true;
        defer if (argv_owned) freeEntries(self.allocator, argv);
        if (!try self.prepareToLeaveActiveSession()) return false;

        try self.activePresentation().pane_renderers.ensureUnusedCapacity(self.allocator, 1);
        const expected_session = session.SessionId.fromOrdinal(@intCast(self.activeWorkspace().registeredSessionCount()));
        var pane_renderer = try self.newPaneRenderer(expected_session);
        var renderer_owned = true;
        errdefer if (renderer_owned) pane_renderer.deinit();
        const created = try self.activeWorkspace().createTab(fileReferenceLabel(path), self.activeLive().terminal().gridSize());
        pane_renderer.session_id = created.session_id;
        self.activePresentation().pane_renderers.appendAssumeCapacity(pane_renderer);
        renderer_owned = false;
        try self.adoptActiveTab();
        self.editor_spawn_observer.observe(argv, cwd);
        cwd_owned = false;
        argv_owned = false;
        self.startTabChildWith(created.session_id, cwd, argv);
        return true;
    }

    fn clipboardCopyAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (self.activeUiTree().focusedInput()) |field| {
            const selected = field.selection();
            if (selected.isEmpty()) return;
            const text = field.text()[selected.start..selected.end];
            platform.setClipboardText(self.allocator, text) catch |err| {
                log.warn("copy of {d} focused-input byte(s) failed: {s}", .{ text.len, @errorName(err) });
                return;
            };
            log.info("copied {d} byte(s) from focused input to the clipboard", .{text.len});
            return;
        }
        if (!self.presentedLive().terminal().hasSelection()) return;
        const copied = self.copySelectionTo(.standard) catch |err| {
            log.warn("terminal selection copy failed: {s}", .{@errorName(err)});
            return;
        };
        log.info("copied {d} byte(s) to the clipboard", .{copied});
    }

    fn clipboardPasteAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (self.activeUiTree().focusedInput()) |field| {
            const text = platform.getClipboardText(self.allocator) catch |err| {
                log.warn("focused-input clipboard read failed: {s}", .{@errorName(err)});
                return;
            };
            defer self.allocator.free(text);
            field.paste(text) catch |err| {
                log.warn("paste of {d} byte(s) into focused input rejected: {s}", .{ text.len, @errorName(err) });
                return;
            };
            if (field == &self.palette_query and self.palette_step == .commands) {
                self.palette_model.refresh(field.text());
            }
            if (field == &self.search_query and self.search_visible) self.restartSearch();
            try self.refreshActiveUi();
            return;
        }
        self.paste(.standard);
    }

    fn sidebarToggleAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (!self.sidebar_enabled) return;
        self.sidebar_visible = !self.sidebar_visible;
        self.sidebar_dragging = false;
        try self.syncGrid();
        try self.composeUi();
        self.invalidateUi();
    }

    fn sidebarNarrowAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (!self.sidebar_enabled or !self.sidebar_visible) return;
        self.sidebar_width_cols -|= sidebar_resize_step;
        self.sidebar_width_cols = @max(self.sidebar_width_cols, sidebar_min_width);
        try self.syncGrid();
        try self.composeUi();
        self.invalidateUi();
    }

    fn sidebarWidenAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (!self.sidebar_enabled or !self.sidebar_visible) return;
        self.sidebar_width_cols +|= sidebar_resize_step;
        self.sidebar_width_cols = @min(self.sidebar_width_cols, sidebar_max_width);
        try self.syncGrid();
        try self.composeUi();
        self.invalidateUi();
    }

    fn setWorkspaceStatus(self: *App, message: []const u8) void {
        self.workspace_status = message;
        self.invalidateUi();
    }

    fn openWorkspaceActionInput(self: *App, action_name: []const u8) !void {
        if (self.paletteVisible() or self.closeModalActive() or self.rename_tab_id != null or
            self.terminal_key_state.len != 0 or self.terminal_pointer_presses != 0 or
            self.ui_pointer_owned or self.palette_pointer_owned or
            self.scratchpad_ui_pointer_owned or self.scratchpad_terminal_pointer_owned or
            self.sidebar_dragging or self.dragged_divider_id != null or self.dragged_tab_id != null)
        {
            return;
        }
        var definition_index: ?usize = null;
        for (self.actions.definitions(), 0..) |definition, index| {
            if (std.mem.eql(u8, definition.name, action_name)) {
                definition_index = index;
                break;
            }
        }
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        try self.window.stopTextInput();
        clearPaletteInput(&self.palette_argument);
        self.palette_step = .commands;
        try self.beginPaletteArgument(definition_index orelse return);
    }

    fn normalizedWorkspaceDirectory(text: []const u8) []const u8 {
        const trimmed = std.mem.trim(u8, text, std.ascii.whitespace[0..]);
        var end = trimmed.len;
        while (end > 1 and (trimmed[end - 1] == '/' or trimmed[end - 1] == '\\')) {
            if (end == 3 and trimmed[1] == ':') break;
            end -= 1;
        }
        return trimmed[0..end];
    }

    fn workspaceBaseName(directory: []const u8) []const u8 {
        if (std.mem.eql(u8, directory, "/")) return directory;
        var start = directory.len;
        while (start != 0) {
            const byte = directory[start - 1];
            if (byte == '/' or byte == '\\') break;
            start -= 1;
        }
        return if (start == directory.len) directory else directory[start..];
    }

    fn uniqueWorkspaceName(self: *App, base: []const u8) ![]u8 {
        if (self.workspace_registry.keyForName(base) == null) return self.allocator.dupe(u8, base);
        var suffix: usize = 2;
        while (true) : (suffix += 1) {
            const candidate = try std.fmt.allocPrint(self.allocator, "{s} ({d})", .{ base, suffix });
            if (self.workspace_registry.keyForName(candidate) == null) return candidate;
            self.allocator.free(candidate);
        }
    }

    fn workspaceForDirectory(self: *App, directory: []const u8) ?workspace.WorkspaceKey {
        var index: usize = 0;
        while (index < self.workspace_registry.count()) : (index += 1) {
            const key = self.workspace_registry.keyAt(index) orelse continue;
            const presentation = self.presentationByKey(key) orelse continue;
            if (presentation.closing) continue;
            const model = self.workspace_registry.byKey(key) orelse continue;
            if (std.mem.eql(
                u8,
                normalizedWorkspaceDirectory(model.workingDirectory()),
                directory,
            )) return key;
        }
        return null;
    }

    fn createWorkspacePresentation(
        self: *App,
        directory: []const u8,
        name: []const u8,
    ) !*WorkspacePresentation {
        const grid_size = self.activeLive().terminal().gridSize();
        var candidate = try workspace.Workspace.initLocal(
            self.io,
            self.allocator,
            name,
            directory,
            grid_size,
        );
        var candidate_owned = true;
        errdefer if (candidate_owned) candidate.deinit() catch |err| log.warn(
            "could not release a refused workspace: {s}",
            .{@errorName(err)},
        );
        const session_id = try candidate.createSession(.human_terminal, grid_size);
        _ = try candidate.registerTab("Terminal 1", session_id);
        const live = candidate.sessionById(session_id) orelse return error.SessionNotFound;
        live.terminal().setClipboardAccess(.{
            .read_fn = readNativeClipboard,
            .write_fn = writeNativeClipboard,
        });

        var pane_renderer = try self.newPaneRenderer(session_id);
        var pane_renderer_owned = true;
        errdefer if (pane_renderer_owned) pane_renderer.deinit();
        var pane_renderers: std.ArrayList(PaneRenderer) = .empty;
        errdefer pane_renderers.deinit(self.allocator);
        try pane_renderers.ensureUnusedCapacity(self.allocator, 1);
        pane_renderers.appendAssumeCapacity(pane_renderer);
        pane_renderer_owned = false;
        errdefer pane_renderers.items[0].deinit();

        var scratchpad_grid = try render.Grid.init(self.allocator, gridColors(default_palette));
        var scratchpad_grid_owned = true;
        errdefer if (scratchpad_grid_owned) scratchpad_grid.deinit();
        try scratchpad_grid.attachAtlas(self.fonts.atlasPixels(), .{
            .width_px = atlas_width_px,
            .height_px = atlas_height_px,
        });

        try self.workspace_presentations.ensureUnusedCapacity(self.allocator, 1);
        const presentation = try self.allocator.create(WorkspacePresentation);
        errdefer self.allocator.destroy(presentation);
        const key = try self.workspace_registry.insert(&candidate);
        candidate_owned = false;
        presentation.* = .{
            .key = key,
            .active_session_id = session_id,
            .pane_renderers = pane_renderers,
            .scratchpad_grid = scratchpad_grid,
        };
        scratchpad_grid_owned = false;
        self.workspace_presentations.appendAssumeCapacity(presentation);
        return presentation;
    }

    fn workspaceTransitionBlocked(self: *const App) bool {
        const owns_only_activation_key = self.ui_key_state.len == 1 and switch (self.ui_key_state.storage[0].identity) {
            .named => |key| key == .enter,
            .character => false,
        };
        return self.terminal_key_state.len != 0 or
            (self.ui_key_state.len != 0 and !owns_only_activation_key) or
            self.terminal_pointer_presses != 0 or
            self.ui_pointer_owned or self.palette_pointer_owned or self.sidebar_dragging or
            self.dragged_divider_id != null or self.dragged_tab_id != null or
            self.scratchpad_ui_pointer_owned or self.scratchpad_terminal_pointer_owned or
            self.scratchpad_escape_owned or self.rename_tab_id != null;
    }

    fn activeWorkspaceClosing(self: *const App) bool {
        return self.workspace_registry.count() != 0 and self.activePresentationConst().closing;
    }

    fn prepareWorkspaceTransition(self: *App) !bool {
        if (self.workspaceTransitionBlocked()) {
            self.setWorkspaceStatus("workspace switch deferred: input owned");
            return false;
        }
        if (!try self.prepareToLeaveActiveSession()) {
            self.setWorkspaceStatus("workspace switch deferred: input pending");
            return false;
        }
        return true;
    }

    fn focusWorkspaceRow(self: *App, key: workspace.WorkspaceKey) !void {
        if (!self.sidebar_visible) return;
        var storage: [workspace_semantic_capacity]u8 = undefined;
        const semantic = try workspaceSemanticId(&storage, key);
        if (self.ui_tree.focus(.{ .value = semantic })) try self.refreshActiveUi();
    }

    fn commitWorkspaceActivation(self: *App, key: workspace.WorkspaceKey, focus_row: bool) !void {
        const presentation = self.presentationByKey(key) orelse return;
        if (presentation.closing) return;
        try self.workspace_registry.activate(key);
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        try self.window.stopTextInput();
        self.ui_tree.clearFocus();
        self.exit_logged = false;
        for (presentation.pane_renderers.items) |*pane_renderer| pane_renderer.grid.invalidate();
        presentation.scratchpad_grid.invalidate();
        self.overlay_grid.invalidateCanvasOverlay();
        self.needs_present = true;
        try self.syncGrid();
        try self.composeUi();
        if (focus_row and !self.scratchpadVisible()) try self.focusWorkspaceRow(key);
        try self.syncTextInput();
        self.workspace_status = null;
        self.invalidateUi();
    }

    fn activateWorkspaceKey(self: *App, key: workspace.WorkspaceKey, focus_row: bool) !bool {
        const presentation = self.presentationByKey(key) orelse return false;
        if (presentation.closing or self.workspace_registry.byKey(key) == null) return false;
        if (self.closeModalActive() or self.paletteVisible()) return false;
        if (self.workspace_registry.activeKey()) |active_key| {
            if (active_key == key) {
                self.workspace_status = null;
                if (focus_row) try self.focusWorkspaceRow(key) else try self.refreshActiveUi();
                return true;
            }
        }
        if (!try self.prepareWorkspaceTransition()) return false;
        try self.commitWorkspaceActivation(key, focus_row);
        return true;
    }

    fn adjacentWorkspaceKey(self: *App, key: workspace.WorkspaceKey, next: bool) ?workspace.WorkspaceKey {
        const count = self.workspace_registry.count();
        if (count < 2) return null;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const candidate = self.workspace_registry.keyAt(index) orelse continue;
            if (candidate == key) break;
        }
        if (index == count) return null;
        var step: usize = 1;
        while (step < count) : (step += 1) {
            const candidate_index = if (next)
                (index + step) % count
            else
                (index + count - (step % count)) % count;
            const candidate = self.workspace_registry.keyAt(candidate_index) orelse continue;
            const presentation = self.presentationByKey(candidate) orelse continue;
            if (!presentation.closing) return candidate;
        }
        return null;
    }

    fn moveWorkspaceFocus(self: *App, next: bool) !void {
        const focused = self.ui_tree.focusedElement() orelse return;
        const current = workspaceKeyForSemantic(focused.id.value) orelse return;
        const target = self.adjacentWorkspaceKey(current, next) orelse return;
        try self.focusWorkspaceRow(target);
    }

    fn sidebarFocusAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (!self.sidebar_enabled) return;
        if (!self.sidebar_visible) {
            self.sidebar_visible = true;
            self.sidebar_dragging = false;
            try self.syncGrid();
        }
        try self.composeUi();
        try self.focusWorkspaceRow(self.activePresentation().key);
    }

    fn workspaceActivateAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const origin = invocation.origin orelse return;
        const key = workspaceKeyForSemantic(origin.value) orelse return;
        _ = try self.activateWorkspaceKey(key, true);
    }

    fn workspaceCreateAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const supplied = argument(invocation, "directory") orelse {
            try self.openWorkspaceActionInput(workspace_create_action);
            return;
        };
        const directory = normalizedWorkspaceDirectory(supplied);
        if (directory.len == 0) {
            self.setWorkspaceStatus("workspace directory is empty");
            return;
        }
        if (self.workspaceForDirectory(directory)) |existing| {
            _ = try self.activateWorkspaceKey(existing, false);
            return;
        }
        if (self.closeModalActive() or self.paletteVisible() or !try self.prepareWorkspaceTransition()) return;
        const base = std.mem.trim(u8, workspaceBaseName(directory), std.ascii.whitespace[0..]);
        if (base.len == 0) {
            self.setWorkspaceStatus("workspace name is empty");
            return;
        }
        const name = try self.uniqueWorkspaceName(base);
        defer self.allocator.free(name);
        const presentation = try self.createWorkspacePresentation(directory, name);
        self.startPresentationChild(presentation, presentation.active_session_id, .{
            .argv = self.scratchpad_spec.argv,
            .env = self.scratchpad_spec.env,
        });
        self.startScratchpadFor(presentation, false);
        try self.commitWorkspaceActivation(presentation.key, false);
    }

    fn workspaceRenameAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const supplied = argument(invocation, "name") orelse {
            try self.openWorkspaceActionInput(workspace_rename_action);
            return;
        };
        const name = std.mem.trim(u8, supplied, std.ascii.whitespace[0..]);
        if (name.len == 0) {
            self.setWorkspaceStatus("workspace name is empty");
            return;
        }
        self.workspace_registry.rename(self.activePresentation().key, name) catch |err| switch (err) {
            error.EmptyName => {
                self.setWorkspaceStatus("workspace name is empty");
                return;
            },
            error.DuplicateName => {
                self.setWorkspaceStatus("workspace name already exists");
                return;
            },
            error.UnknownWorkspace => {
                self.setWorkspaceStatus("workspace no longer exists");
                return;
            },
            else => return err,
        };
        self.workspace_status = null;
        try self.refreshActiveUi();
    }

    fn workspaceSwitchAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const supplied = argument(invocation, "name") orelse {
            try self.openWorkspaceActionInput(workspace_switch_action);
            return;
        };
        const name = std.mem.trim(u8, supplied, std.ascii.whitespace[0..]);
        if (name.len == 0) {
            self.setWorkspaceStatus("workspace name is empty");
            return;
        }
        const key = self.workspace_registry.keyForName(name) orelse {
            self.setWorkspaceStatus("workspace not found");
            return;
        };
        _ = try self.activateWorkspaceKey(key, false);
    }

    fn workspaceCloseAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (self.closeModalActive()) return;
        self.pending_close_workspace = self.activePresentation().key;
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "workspace-close.cancel" })) try self.refreshActiveUi();
    }

    fn workspaceCloseCancelAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const key = self.pending_close_workspace orelse return;
        self.pending_close_workspace = null;
        try self.composeUi();
        if (!self.scratchpadVisible()) try self.focusWorkspaceRow(key);
        self.invalidateUi();
    }

    fn finalizeClosingPresentations(self: *App) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.workspace_presentations.items.len) {
            const presentation = self.workspace_presentations.items[index];
            if (!presentation.closing or presentation.load != null or presentation.scratchpad_load != null) {
                index += 1;
                continue;
            }
            const result = self.workspace_registry.remove(presentation.key) catch {
                log.err("a closing workspace disappeared before teardown", .{});
                index += 1;
                continue;
            };
            if (result.teardown_error) |err| log.warn(
                "a workspace closed but a child could not be signalled cleanly: {s}",
                .{@errorName(err)},
            );
            for (presentation.pane_renderers.items) |*pane_renderer| pane_renderer.deinit();
            presentation.pane_renderers.deinit(self.allocator);
            presentation.scratchpad_grid.deinit();
            self.allocator.destroy(presentation);
            _ = self.workspace_presentations.orderedRemove(index);
            changed = true;
            if (result.active_key == null) self.requested_shutdown = true;
        }
        return changed;
    }

    fn workspaceCloseConfirmAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const key = self.pending_close_workspace orelse return;
        const presentation = self.presentationByKey(key) orelse {
            self.pending_close_workspace = null;
            return;
        };
        if (!try self.prepareWorkspaceTransition()) return;
        const successor = self.adjacentWorkspaceKey(key, true);
        self.pending_close_workspace = null;
        self.ui_tree.clearFocus();
        if (successor) |next| try self.commitWorkspaceActivation(next, true);
        presentation.closing = true;
        _ = self.finalizeClosingPresentations();
        if (!self.requested_shutdown) {
            try self.composeUi();
            self.invalidateUi();
        }
    }

    fn tabActivateAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const origin = invocation.origin orelse return;
        const id = self.tabIdForSemantic(origin.value) orelse return;
        _ = try self.activateTab(id);
    }

    fn workspaceKeyForSemantic(semantic_id: []const u8) ?workspace.WorkspaceKey {
        const prefix = "workspace.";
        if (!std.mem.startsWith(u8, semantic_id, prefix)) return null;
        const encoded = semantic_id[prefix.len..];
        if (encoded.len == 0 or std.mem.indexOfScalar(u8, encoded, '.') != null) return null;
        const value = std.fmt.parseUnsigned(u64, encoded, 10) catch return null;
        if (value == 0) return null;
        return @enumFromInt(value);
    }

    fn workspaceEntityForSemantic(semantic_id: []const u8, kind: []const u8) ?WorkspaceSemanticTarget {
        const prefix = "workspace.";
        if (!std.mem.startsWith(u8, semantic_id, prefix)) return null;
        const suffix = semantic_id[prefix.len..];
        const key_end = std.mem.indexOfScalar(u8, suffix, '.') orelse return null;
        const key_value = std.fmt.parseUnsigned(u64, suffix[0..key_end], 10) catch return null;
        if (key_value == 0) return null;
        const entity = suffix[key_end + 1 ..];
        if (!std.mem.startsWith(u8, entity, kind) or entity.len <= kind.len or entity[kind.len] != '.') return null;
        const ordinal = std.fmt.parseUnsigned(u32, entity[kind.len + 1 ..], 10) catch return null;
        if (ordinal == 0) return null;
        return .{ .key = @enumFromInt(key_value), .ordinal = ordinal };
    }

    fn tabIdForSemantic(self: *const App, semantic_id: []const u8) ?workspace.TabId {
        const target = workspaceEntityForSemantic(semantic_id, "tab") orelse return null;
        const active_key = self.workspace_registry.activeKey() orelse return null;
        if (target.key != active_key) return null;
        const id: workspace.TabId = @enumFromInt(target.ordinal);
        if (self.activeWorkspaceConst().tab(id) == null) return null;
        return id;
    }

    fn focusTabRow(self: *App, id: workspace.TabId) !void {
        var storage: [workspace_semantic_capacity]u8 = undefined;
        const semantic = try tabSemanticId(&storage, self.activePresentation().key, id);
        _ = self.ui_tree.focus(.{ .value = semantic });
    }

    fn activeTabRenameSemantic(self: *App, storage: []u8) ![]const u8 {
        return tabRenameSemanticId(storage, self.activePresentation().key);
    }

    fn targetTab(self: *const App, invocation: inputmod.Invocation) ?workspace.TabId {
        if (invocation.source == .mouse) {
            const origin = invocation.origin orelse return null;
            if (std.mem.startsWith(u8, origin.value, "workspace.")) {
                return self.tabIdForSemantic(origin.value);
            }
            const active_control = std.mem.eql(u8, origin.value, "tabs.close") or
                std.mem.eql(u8, origin.value, "tabs.rename") or
                std.mem.eql(u8, origin.value, "tabs.move-up") or
                std.mem.eql(u8, origin.value, "tabs.move-down");
            if (!active_control) return null;
        }
        return self.activeWorkspaceConst().activeTabId();
    }

    fn hasPendingTerminalInput(self: *const App) bool {
        const presented = self.presentedLiveConst();
        return (TerminalInputDebt{
            .encoded = self.child_input.len,
            .staged = self.pending_child_bytes.items.len,
            .committed = self.pending_committed_text.len,
            .paste = self.pending_paste != null,
            .responses = presented.pendingResponseBytes(),
        }).remains();
    }

    fn closeModalActive(self: *const App) bool {
        return self.pending_close_workspace != null or self.pending_close_tab_id != null or self.pending_close_pane != null;
    }

    fn prepareToLeaveActiveSession(self: *App) !bool {
        try self.flushToChild();
        if (!self.hasPendingTerminalInput()) return true;
        log.warn("session change deferred while input or terminal responses are pending", .{});
        return false;
    }

    fn adoptFocusedPane(self: *App) !void {
        const tab_id = self.activeWorkspace().activeTabId() orelse return error.SessionNotFound;
        const session_id = self.activeWorkspace().focusedPaneSessionId(tab_id) orelse return error.SessionNotFound;
        const live = self.activeWorkspace().sessionById(session_id) orelse return error.SessionNotFound;
        _ = self.rendererForSession(session_id) orelse return error.SessionNotFound;
        self.activePresentation().active_session_id = session_id;
        live.terminal().setClipboardAccess(.{
            .read_fn = readNativeClipboard,
            .write_fn = writeNativeClipboard,
        });
        self.exit_logged = false;
        try self.syncGrid();
        try self.syncTextInput();
        try self.composeUi();
        self.invalidateUi();
    }

    fn adoptActiveTab(self: *App) !void {
        try self.adoptFocusedPane();
    }

    fn activateTab(self: *App, id: workspace.TabId) !bool {
        _ = self.activeWorkspace().tab(id) orelse return false;
        if (self.activeWorkspace().focusedPaneSessionId(id) == self.activePresentation().active_session_id) {
            try self.activeWorkspace().activateTab(id);
            try self.refreshActiveUi();
            return true;
        }
        if (!try self.prepareToLeaveActiveSession()) return false;
        try self.activeWorkspace().activateTab(id);
        try self.adoptActiveTab();
        return true;
    }

    fn tabNewAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (self.activePresentation().load != null) {
            log.warn("new tab deferred while another load is in flight", .{});
            return;
        }
        if (!try self.prepareToLeaveActiveSession()) return;

        const inherited = self.activeLive().workingDirectory() orelse self.activeWorkspace().workingDirectory();
        const cwd = try self.allocator.dupe(u8, inherited);
        errdefer self.allocator.free(cwd);
        try self.activePresentation().pane_renderers.ensureUnusedCapacity(self.allocator, 1);
        const expected_session = session.SessionId.fromOrdinal(@intCast(self.activeWorkspace().registeredSessionCount()));
        var pane_renderer = try self.newPaneRenderer(expected_session);
        var renderer_owned = true;
        errdefer if (renderer_owned) pane_renderer.deinit();
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buffer,
            "Terminal {d}",
            .{self.activeWorkspace().registeredSessionCount()},
        );
        const created = try self.activeWorkspace().createTab(name, self.activeLive().terminal().gridSize());
        pane_renderer.session_id = created.session_id;
        self.activePresentation().pane_renderers.appendAssumeCapacity(pane_renderer);
        renderer_owned = false;
        try self.adoptActiveTab();
        self.startTabChild(created.session_id, cwd);
    }

    fn sessionNeedsCloseConfirmation(live: *session.Session) bool {
        const child = live.child() orelse return false;
        if (child.state() != .running) return false;
        return !(live.hasSeenPromptMarks() and live.cursorIsAtPrompt());
    }

    fn tabNeedsCloseConfirmation(self: *App, tab_id: workspace.TabId) bool {
        var ordinal: usize = 0;
        while (ordinal < self.activeWorkspace().registeredSessionCount()) : (ordinal += 1) {
            const session_id = session.SessionId.fromOrdinal(@intCast(ordinal));
            const location = self.activeWorkspace().paneForSession(session_id) orelse continue;
            if (location.tab_id != tab_id) continue;
            const live = self.activeWorkspace().sessionById(session_id) orelse continue;
            if (sessionNeedsCloseConfirmation(live)) return true;
        }
        return false;
    }

    fn tabCloseAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const id = self.targetTab(invocation) orelse return;
        _ = self.activeWorkspace().tab(id) orelse return;
        if (!self.tabNeedsCloseConfirmation(id)) return self.closeTab(id);

        self.pending_close_pane = null;
        self.pending_close_tab_id = id;
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "tab-close.cancel" })) try self.refreshActiveUi();
    }

    fn tabCloseConfirmAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (self.pending_close_pane) |target| {
            // Keep the modal and its bounded focus trap intact until every byte
            // already owed to the pane being closed has actually reached it.
            if (!try self.prepareToLeaveActiveSession()) return;
            self.pending_close_pane = null;
            self.pending_close_tab_id = null;
            // The modal's focused confirmation choice must not remain the
            // keyboard owner after its protected pane is gone. In particular,
            // the next Enter belongs to the newly focused terminal.
            self.ui_tree.clearFocus();
            try self.closePane(target.tab_id, target.pane_id);
            return;
        }
        const tab_id = self.pending_close_tab_id orelse return;
        if (self.activeWorkspace().activeTabId() == tab_id and
            self.activeWorkspace().tabCount() > 1 and
            !try self.prepareToLeaveActiveSession()) return;
        self.pending_close_tab_id = null;
        self.ui_tree.clearFocus();
        try self.closeTab(tab_id);
    }

    fn tabCloseCancelAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const tab_id = self.pending_close_tab_id;
        const pane_target = self.pending_close_pane;
        if (tab_id == null and pane_target == null) return;
        self.pending_close_tab_id = null;
        self.pending_close_pane = null;
        try self.composeUi();
        if (tab_id) |id| {
            if (!self.scratchpadVisible() and self.activeWorkspace().tab(id) != null) try self.focusTabRow(id);
        }
        if (pane_target != null or self.scratchpadVisible()) self.ui_tree.clearFocus();
        try self.refreshActiveUi();
    }

    fn closeTab(self: *App, id: workspace.TabId) !void {
        if (self.activeWorkspace().tabCount() == 1) {
            // Closing the final tab follows the common terminal convention:
            // leave the app and let normal reverse-order teardown stop it.
            self.requested_shutdown = true;
            return;
        }
        const was_active = self.activeWorkspace().activeTabId() == id;
        if (was_active and !try self.prepareToLeaveActiveSession()) return;
        self.activeWorkspace().closeTab(id) catch |err| {
            log.warn("the tab closed but its child could not be signalled cleanly: {s}", .{@errorName(err)});
        };
        self.discardClosedPaneRenderers();
        if (was_active) {
            try self.adoptActiveTab();
        } else {
            try self.composeUi();
            self.invalidateUi();
        }
    }

    fn tabRenameAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const id = self.targetTab(invocation) orelse return;
        const tab = self.activeWorkspace().tab(id) orelse return;
        if (self.rename_input) |*field| field.deinit();
        self.rename_input = try ui.Input.init(self.allocator, tab_name_capacity, tab.name());
        self.rename_tab_id = id;
        try self.composeUi();
        var storage: [workspace_semantic_capacity]u8 = undefined;
        if (self.ui_tree.focus(.{ .value = try self.activeTabRenameSemantic(&storage) })) try self.refreshActiveUi();
    }

    fn tabRenameCommitAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const id = self.rename_tab_id orelse return;
        const field = if (self.rename_input) |*value| value else return;
        const name = std.mem.trim(u8, field.text(), std.ascii.whitespace[0..]);
        if (name.len == 0) {
            log.warn("an empty tab name was not saved", .{});
            return;
        }
        try self.activeWorkspace().renameTab(id, name);
        field.deinit();
        self.rename_input = null;
        self.rename_tab_id = null;
        try self.composeUi();
        if (self.activeWorkspace().tab(id) != null) try self.focusTabRow(id);
        try self.refreshActiveUi();
    }

    fn tabRenameCancelAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const id = self.rename_tab_id orelse return;
        if (self.rename_input) |*field| field.deinit();
        self.rename_input = null;
        self.rename_tab_id = null;
        try self.composeUi();
        if (self.activeWorkspace().tab(id) != null) try self.focusTabRow(id);
        try self.refreshActiveUi();
    }

    fn tabPreviousAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const count = self.activeWorkspace().tabCount();
        if (count < 2) return;
        const active = self.activeWorkspace().activeTabId() orelse return;
        const index = self.activeWorkspace().tabIndex(active) orelse return;
        const target = self.activeWorkspace().tabAt(if (index == 0) count - 1 else index - 1) orelse return;
        _ = try self.activateTab(target.id());
    }

    fn tabNextAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const count = self.activeWorkspace().tabCount();
        if (count < 2) return;
        const active = self.activeWorkspace().activeTabId() orelse return;
        const index = self.activeWorkspace().tabIndex(active) orelse return;
        const target = self.activeWorkspace().tabAt((index + 1) % count) orelse return;
        _ = try self.activateTab(target.id());
    }

    fn argument(invocation: inputmod.Invocation, name: []const u8) ?[]const u8 {
        for (invocation.arguments) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
        return null;
    }

    fn tabGotoAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const text = argument(invocation, "index") orelse return;
        const one_based = std.fmt.parseUnsigned(usize, text, 10) catch return;
        if (one_based == 0) return;
        const tab = self.activeWorkspace().tabAt(one_based - 1) orelse return;
        _ = try self.activateTab(tab.id());
    }

    fn tabMoveAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const id = self.targetTab(invocation) orelse return;
        const index = self.activeWorkspace().tabIndex(id) orelse return;
        const direction = argument(invocation, "direction") orelse if (invocation.origin) |origin|
            if (std.mem.eql(u8, origin.value, "tabs.move-up")) "up" else if (std.mem.eql(u8, origin.value, "tabs.move-down")) "down" else return
        else
            return;
        const final_index = if (std.mem.eql(u8, direction, "up"))
            index -| 1
        else if (std.mem.eql(u8, direction, "down"))
            @min(index +| 1, self.activeWorkspace().tabCount() - 1)
        else
            return;
        try self.activeWorkspace().moveTab(id, final_index);
        try self.refreshActiveUi();
    }

    fn tabReorderAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const source = invocation.origin orelse return;
        const source_id = self.tabIdForSemantic(source.value) orelse return;
        const target_id = self.tabIdForSemantic(argument(invocation, "target") orelse return) orelse return;
        const final_index = self.activeWorkspace().tabIndex(target_id) orelse return;
        try self.activeWorkspace().moveTab(source_id, final_index);
        try self.refreshActiveUi();
    }

    fn sidebarResizeAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = context;
        _ = invocation;
        // Drag motion owns resizing; release still resolves through the action
        // registry so the divider obeys the same semantic interaction path.
    }

    fn paneIdForSemantic(self: *const App, semantic_id: []const u8) ?workspace.PaneId {
        const target = workspaceEntityForSemantic(semantic_id, "pane") orelse return null;
        const active_key = self.workspace_registry.activeKey() orelse return null;
        if (target.key != active_key) return null;
        const id: workspace.PaneId = @enumFromInt(target.ordinal);
        const tab_id = self.activeWorkspaceConst().activeTabId() orelse return null;
        if (self.activeWorkspaceConst().paneSessionId(tab_id, id) == null) return null;
        return id;
    }

    fn dividerIdForSemantic(self: *const App, semantic_id: []const u8) ?workspace.DividerId {
        const target = workspaceEntityForSemantic(semantic_id, "divider") orelse return null;
        const active_key = self.workspace_registry.activeKey() orelse return null;
        if (target.key != active_key) return null;
        const id: workspace.DividerId = @enumFromInt(target.ordinal);
        for (self.divider_layouts[0..self.divider_layout_count]) |divider| {
            if (divider.divider_id == id) return id;
        }
        return null;
    }

    fn paneDirection(text: []const u8) ?workspace.PaneDirection {
        if (std.mem.eql(u8, text, "left")) return .left;
        if (std.mem.eql(u8, text, "right")) return .right;
        if (std.mem.eql(u8, text, "up")) return .up;
        if (std.mem.eql(u8, text, "down")) return .down;
        return null;
    }

    fn panePressRoutesToTerminal(clicked: workspace.PaneId, focused_after: ?workspace.PaneId) bool {
        return focused_after != null and focused_after.? == clicked;
    }

    fn paneMotionOwnedByUi(
        existing_gesture: bool,
        pane_under_pointer: ?workspace.PaneId,
        focused: ?workspace.PaneId,
        buttons: platform.ButtonsHeld,
    ) bool {
        if (existing_gesture) return true;
        const pane_id = pane_under_pointer orelse return false;
        return pane_id != focused and !buttons.left and !buttons.middle and !buttons.right;
    }

    fn paneActivateAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const origin = invocation.origin orelse return;
        const pane_id = self.paneIdForSemantic(origin.value) orelse return;
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        if (self.activeWorkspace().focusedPaneId(tab_id) == pane_id) return;
        if (!try self.prepareToLeaveActiveSession()) return;
        try self.activeWorkspace().focusPane(tab_id, pane_id);
        try self.adoptFocusedPane();
    }

    fn paneSplitAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        if (self.activePresentation().load != null) {
            log.warn("pane split deferred while another load is in flight", .{});
            return;
        }
        if (!try self.prepareToLeaveActiveSession()) return;
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        const tab = self.activeWorkspace().tab(tab_id) orelse return;
        if (tab.paneCount() >= pane_ui_capacity) {
            log.warn("pane split refused because the semantic frame is full", .{});
            return;
        }
        const focused_pane = self.activeWorkspace().focusedPaneId(tab_id) orelse return;
        const split_text = argument(invocation, "direction") orelse if (invocation.origin) |origin|
            if (std.mem.eql(u8, origin.value, "panes.split-right")) "right" else if (std.mem.eql(u8, origin.value, "panes.split-down")) "down" else return
        else
            return;
        const split: workspace.PaneSplit = if (std.mem.eql(u8, split_text, "right"))
            .right
        else if (std.mem.eql(u8, split_text, "down"))
            .down
        else
            return;
        const bounds = self.terminalCellBounds() orelse return;
        const inherited = self.activeLive().workingDirectory() orelse self.activeWorkspace().workingDirectory();
        const cwd = try self.allocator.dupe(u8, inherited);
        errdefer self.allocator.free(cwd);
        try self.activePresentation().pane_renderers.ensureUnusedCapacity(self.allocator, 1);
        const expected_session = session.SessionId.fromOrdinal(@intCast(self.activeWorkspace().registeredSessionCount()));
        var pane_renderer = try self.newPaneRenderer(expected_session);
        var renderer_owned = true;
        errdefer if (renderer_owned) pane_renderer.deinit();
        const created = self.activeWorkspace().createPaneSession(
            tab_id,
            focused_pane,
            .human_terminal,
            self.activeLive().terminal().gridSize(),
            split,
            bounds,
        ) catch |err| {
            if (err == error.InvalidGeometry) return;
            return err;
        };
        pane_renderer.session_id = created.session_id;
        self.activePresentation().pane_renderers.appendAssumeCapacity(pane_renderer);
        renderer_owned = false;
        try self.adoptFocusedPane();
        self.startTabChild(created.session_id, cwd);
    }

    fn paneFocusAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const direction = paneDirection(argument(invocation, "direction") orelse return) orelse return;
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        const bounds = self.terminalCellBounds() orelse return;
        if (!try self.prepareToLeaveActiveSession()) return;
        const moved = self.activeWorkspace().focusPaneDirection(tab_id, direction, bounds) catch |err| switch (err) {
            error.InvalidGeometry => return,
            else => return err,
        };
        if (!moved) return;
        try self.adoptFocusedPane();
    }

    fn paneResizeAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        const bounds = self.terminalCellBounds() orelse return;
        var changed = false;
        if (argument(invocation, "divider")) |divider_text| {
            const value = std.fmt.parseUnsigned(u32, divider_text, 10) catch return;
            if (value == 0) return;
            const delta = std.fmt.parseInt(i32, argument(invocation, "delta") orelse return, 10) catch return;
            changed = self.activeWorkspace().resizeDivider(tab_id, @enumFromInt(value), delta, bounds) catch |err| switch (err) {
                error.InvalidGeometry, error.UnknownDivider => return,
                else => return err,
            };
        } else {
            const direction = paneDirection(argument(invocation, "direction") orelse return) orelse return;
            const pane_id = self.activeWorkspace().focusedPaneId(tab_id) orelse return;
            changed = self.activeWorkspace().resizePaneEdge(tab_id, pane_id, direction, 1, bounds) catch |err| switch (err) {
                error.InvalidGeometry, error.UnknownDivider => return,
                else => return err,
            };
        }
        if (!changed) return;
        try self.syncGrid();
        try self.composeUi();
        self.invalidateUi();
    }

    fn paneZoomAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        _ = try self.activeWorkspace().togglePaneZoom(tab_id);
        try self.syncGrid();
        try self.composeUi();
        self.invalidateUi();
    }

    fn paneCloseAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        const tab_id = self.activeWorkspace().activeTabId() orelse return;
        const tab = self.activeWorkspace().tab(tab_id) orelse return;
        if (tab.paneCount() == 1) {
            try tabCloseAction(self, .{ .source = .palette });
            return;
        }
        const pane_id = self.activeWorkspace().focusedPaneId(tab_id) orelse return;
        const session_id = self.activeWorkspace().paneSessionId(tab_id, pane_id) orelse return;
        const target = self.activeWorkspace().sessionById(session_id) orelse return;
        if (!sessionNeedsCloseConfirmation(target)) {
            if (!try self.prepareToLeaveActiveSession()) return;
            // A sidebar click focused this control before invoking it. Once an
            // idle pane closes directly, keyboard input belongs to the adopted
            // sibling terminal rather than to the still-present close control.
            self.ui_tree.clearFocus();
            return self.closePane(tab_id, pane_id);
        }
        self.pending_close_tab_id = null;
        self.pending_close_pane = .{ .tab_id = tab_id, .pane_id = pane_id };
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "tab-close.cancel" })) try self.refreshActiveUi();
    }

    fn closePane(self: *App, tab_id: workspace.TabId, pane_id: workspace.PaneId) !void {
        const result = self.activeWorkspace().closePane(tab_id, pane_id) catch |err| {
            self.discardClosedPaneRenderers();
            if (self.activeWorkspace().paneSessionId(tab_id, pane_id) == null) {
                try self.adoptFocusedPane();
                log.warn("the pane closed but its child could not be signalled cleanly: {s}", .{@errorName(err)});
                return;
            }
            return err;
        };
        switch (result) {
            .pane_closed => {
                self.discardClosedPaneRenderers();
                try self.adoptFocusedPane();
            },
            .close_tab => try self.closeTab(tab_id),
        }
    }

    fn setScratchpadPresentation(self: *App, requested: ScratchpadPresentation) !void {
        if (self.closeModalActive()) return;
        const next: ScratchpadPresentation = if (requested == self.activePresentation().scratchpad_presentation)
            .hidden
        else
            requested;
        const changes_session = (self.activePresentation().scratchpad_presentation == .hidden) != (next == .hidden);
        if (changes_session and !try self.prepareToLeaveActiveSession()) return;

        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        try self.window.stopTextInput();
        self.ui_tree.clearFocus();
        self.ui_pointer_owned = false;
        self.activePresentation().scratchpad_presentation = next;
        try self.syncGrid();
        try self.syncTextInput();
        try self.composeUi();
        self.invalidateUi();
    }

    fn scratchpadToggle50Action(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.setScratchpadPresentation(.fifty);
    }

    fn scratchpadToggle90Action(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.setScratchpadPresentation(.ninety);
    }

    fn scratchpadHideAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        if (!try self.scratchpadActionTargetsActive(invocation, "hide")) return;
        if (!self.scratchpadVisible()) return;
        try self.setScratchpadPresentation(.hidden);
    }

    fn scratchpadRestartAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        if (!try self.scratchpadActionTargetsActive(invocation, "restart")) return;
        if (self.activePresentation().scratchpad_load != null) return;
        if (self.scratchpadVisible() and !try self.prepareToLeaveActiveSession()) return;
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        // A pointer activation focuses the restart text. Leaving that focus in
        // place would make the next Enter activate restart again instead of
        // reaching the fresh shell.
        self.ui_tree.clearFocus();
        try self.refreshActiveUi();
        const replacement = if (self.scratchpadLive()) |scratchpad| scratchpad.child() != null else false;
        self.startScratchpad(replacement);
    }

    fn scratchpadActionTargetsActive(
        self: *const App,
        invocation: inputmod.Invocation,
        suffix: []const u8,
    ) !bool {
        if (invocation.source != .mouse) return true;
        const origin = invocation.origin orelse return false;
        var storage: [workspace_semantic_capacity]u8 = undefined;
        const expected = try scratchpadSemanticId(&storage, self.activePresentationConst().key, suffix);
        return std.mem.eql(u8, origin.value, expected);
    }

    fn clearPaletteInput(field: *ui.Input) void {
        field.selectAll();
        field.backspace();
    }

    fn paletteSemanticIndex(id: []const u8, prefix: []const u8) ?usize {
        if (!std.mem.startsWith(u8, id, prefix)) return null;
        return std.fmt.parseUnsigned(usize, id[prefix.len..], 10) catch null;
    }

    fn paletteChoiceSemanticIndex(id: []const u8, definition_index: usize) ?usize {
        const prefix = "palette.choice.";
        if (!std.mem.startsWith(u8, id, prefix)) return null;
        const suffix = id[prefix.len..];
        const separator = std.mem.indexOfScalar(u8, suffix, '.') orelse return null;
        const encoded_definition = std.fmt.parseUnsigned(usize, suffix[0..separator], 10) catch return null;
        if (encoded_definition != definition_index) return null;
        return std.fmt.parseUnsigned(usize, suffix[separator + 1 ..], 10) catch null;
    }

    fn isSearchAction(name: []const u8) bool {
        return std.mem.startsWith(u8, name, "search.") or
            std.mem.eql(u8, name, clipboard_copy_action) or
            std.mem.eql(u8, name, clipboard_paste_action);
    }

    fn stopSearchEngine(self: *App) void {
        if (self.search_engine_live) self.search_engine.deinit();
        self.search_engine_live = false;
        self.search_session_id = null;
        self.search_page_slot = 0;
        self.search_page_scan = null;
        self.search_match_count = 0;
        self.search_active_index = 0;
        self.search_progress = .complete;
        self.search_truncated = false;
        self.search_needs_sync = false;
        self.search_restart_on_sync = false;
        self.search_follow_pending = false;
    }

    fn startSearchPage(
        self: *App,
        cursor: term.SearchCursor,
        activation: SearchPageActivation,
        allow_wrap: bool,
        preserve_current: bool,
    ) void {
        const slot = if (preserve_current) 1 - self.search_page_slot else self.search_page_slot;
        self.search_page_scan = .{
            .cursor = cursor,
            .slot = slot,
            .activation = activation,
            .allow_wrap = allow_wrap,
        };
        if (!preserve_current) {
            self.search_match_count = 0;
            self.search_active_index = 0;
        }
    }

    fn startInitialSearchPage(self: *App) bool {
        const cursor = self.search_engine.startCursor(
            self.presentedLive().terminal(),
            .older,
        ) catch |err| {
            self.stopSearchEngine();
            self.search_failure = @errorName(err);
            return false;
        };
        self.startSearchPage(cursor, .first, false, false);
        return true;
    }

    fn restartSearch(self: *App) void {
        self.stopSearchEngine();
        self.search_failure = null;
        if (!self.search_visible or self.search_query.text().len == 0) return;

        const live = self.presentedLive();
        (switch (self.search_mode) {
            .literal => self.search_engine.init(
                live.terminal(),
                self.search_query.text(),
                self.search_case,
                &self.search_scratch,
            ),
            .regex => self.search_engine.initRegex(
                live.terminal(),
                self.search_query.text(),
                self.search_case,
                &self.search_scratch,
            ),
        }) catch |err| {
            self.search_failure = searchFailureText(err);
            return;
        };
        self.search_engine_live = true;
        self.search_session_id = self.presentedSessionId();
        self.search_progress = .running;
        self.search_follow_pending = true;
        _ = self.startInitialSearchPage();
    }

    fn noteSearchTerminalChange(self: *App, id: session.SessionId) void {
        if (!self.search_engine_live or self.search_session_id != id) return;
        self.search_needs_sync = true;
        self.search_restart_on_sync = self.search_progress == .scratch_exhausted;
        self.search_page_scan = null;
        self.search_match_count = 0;
        self.search_active_index = 0;
        self.search_progress = .running;
        self.search_truncated = false;
        self.search_follow_pending = true;
    }

    fn revealActiveSearchMatch(self: *App) bool {
        if (self.search_match_count == 0 or self.search_active_index >= self.search_match_count) return false;
        const live = self.presentedLive();
        const moved = live.terminal().revealSearchMatch(
            self.search_pages[self.search_page_slot][self.search_active_index].match,
        ) catch |err| switch (err) {
            error.StaleSearchMatch => {
                self.noteSearchTerminalChange(self.presentedSessionId());
                return false;
            },
            error.NotOwned => {
                self.search_failure = @errorName(err);
                return false;
            },
        };
        return moved;
    }

    fn finishSearchPage(self: *App, state: SearchPageScan) void {
        if (state.cursor.direction == .newer) {
            std.mem.reverse(term.LocatedSearchMatch, self.search_pages[state.slot][0..state.count]);
        }
        self.search_page_slot = state.slot;
        self.search_match_count = state.count;
        self.search_active_index = switch (state.activation) {
            .first => 0,
            .last => state.count - 1,
        };
        self.search_page_scan = null;
        self.search_truncated = state.count == search_match_capacity or state.wrapped;
        self.search_follow_pending = true;
    }

    fn wrapSearchPage(self: *App, state: SearchPageScan) bool {
        const cursor = self.search_engine.startCursor(
            self.presentedLive().terminal(),
            state.cursor.direction,
        ) catch |err| {
            self.stopSearchEngine();
            self.search_failure = @errorName(err);
            return false;
        };
        var wrapped = state;
        wrapped.cursor = cursor;
        wrapped.count = 0;
        wrapped.wrapped = true;
        self.search_page_scan = wrapped;
        return true;
    }

    fn searchNeedsWork(self: *const App) bool {
        return searchWorkPending(
            self.search_visible,
            self.search_engine_live,
            self.search_needs_sync,
            self.search_progress,
            self.search_page_scan != null,
        );
    }

    /// Run a bounded number of page ticks from the event-loop poll, never from
    /// composition or rendering. Returns whether semantic or viewport state
    /// changed and therefore a frame is owed.
    fn advanceSearch(self: *App) bool {
        if (!self.search_visible or !self.search_engine_live) return false;
        if (self.search_session_id != self.presentedSessionId()) {
            self.stopSearchEngine();
            self.search_failure = "terminal changed";
            return true;
        }

        if (self.search_needs_sync) {
            if (self.search_restart_on_sync) {
                self.restartSearch();
                return true;
            }
            self.search_engine.sync(self.presentedLive().terminal(), true) catch |err| {
                if (err == error.SearchScratchExhausted) {
                    self.restartSearch();
                } else {
                    self.stopSearchEngine();
                    self.search_failure = searchFailureText(err);
                }
                return true;
            };
            self.search_needs_sync = false;
            self.search_restart_on_sync = false;
            self.search_resync_count +%= 1;
            if (!self.startInitialSearchPage()) return true;
        }

        const before_count = self.search_match_count;
        const before_progress = self.search_progress;
        const before_slot = self.search_page_slot;
        const before_active = self.search_active_index;
        if (self.search_progress == .running) {
            self.search_progress = self.search_engine.step(search_tick_budget) catch |err| {
                self.stopSearchEngine();
                self.search_failure = searchFailureText(err);
                return true;
            };
        }

        if (self.search_page_scan) |pending| {
            var state = pending;
            const scan = self.search_engine.scan(
                self.presentedLive().terminal(),
                &state.cursor,
                search_candidate_budget,
                self.search_pages[state.slot][state.count..],
            ) catch |err| {
                self.stopSearchEngine();
                self.search_failure = searchFailureText(err);
                return true;
            };
            state.count += scan.items.len;
            self.search_progress = scan.progress;
            self.search_page_scan = state;
            if (state.slot == self.search_page_slot) self.search_match_count = state.count;

            switch (scan.stop) {
                .budget => {},
                .output_full => self.finishSearchPage(state),
                .scratch_exhausted => {
                    if (state.count != 0) self.finishSearchPage(state) else self.search_page_scan = null;
                    self.search_progress = .scratch_exhausted;
                },
                .current_boundary => {
                    if (self.search_progress == .running) {
                        // Keep the raw cursor at today's boundary. Older
                        // candidates append beyond it as engine ticks land.
                    } else if (state.count != 0) {
                        self.finishSearchPage(state);
                    } else if (state.allow_wrap and !state.wrapped) {
                        if (!self.wrapSearchPage(state)) return true;
                    } else {
                        self.search_page_scan = null;
                    }
                },
            }
        }

        var changed = before_count != self.search_match_count or
            before_progress != self.search_progress or
            before_slot != self.search_page_slot or
            before_active != self.search_active_index;
        if (self.search_follow_pending and self.search_match_count != 0) {
            changed = self.revealActiveSearchMatch() or changed;
            self.search_follow_pending = false;
        } else if (self.search_progress == .complete) {
            self.search_follow_pending = false;
        }
        return changed;
    }

    fn openSearch(self: *App) !void {
        if (self.closeModalActive() or self.rename_tab_id != null) return;
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        self.search_visible = true;
        self.ui_tree.clearFocus();
        self.restartSearch();
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "search.query" })) try self.composeUi();
        try self.syncTextInput();
        self.invalidateUi();
    }

    fn closeSearch(self: *App) !void {
        if (!self.search_visible) return;
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        self.stopSearchEngine();
        self.search_visible = false;
        self.search_pointer_owned = false;
        self.ui_tree.clearFocus();
        try self.composeUi();
        try self.syncTextInput();
        self.invalidateUi();
    }

    fn moveSearchSelection(self: *App, next: bool) !void {
        if (!self.search_visible or self.search_match_count == 0) return;
        if (self.search_page_scan != null) return;

        if (next and self.search_active_index + 1 < self.search_match_count) {
            self.search_active_index += 1;
            _ = self.revealActiveSearchMatch();
        } else if (!next and self.search_active_index != 0) {
            self.search_active_index -= 1;
            _ = self.revealActiveSearchMatch();
        } else {
            const anchor = self.search_pages[self.search_page_slot][self.search_active_index];
            const direction: term.SearchDirection = if (next) .older else .newer;
            const cursor = self.search_engine.cursorAfter(
                self.presentedLive().terminal(),
                anchor,
                direction,
            ) catch |err| {
                self.stopSearchEngine();
                self.search_failure = @errorName(err);
                return;
            };
            self.startSearchPage(cursor, if (next) .first else .last, true, true);
        }
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "search.query" })) try self.composeUi();
        self.invalidateUi();
    }

    fn searchMatchSemanticIndex(id: []const u8) ?usize {
        const prefix = "search.match.";
        if (!std.mem.startsWith(u8, id, prefix)) return null;
        const suffix = id[prefix.len..];
        const separator = std.mem.indexOfScalar(u8, suffix, '.') orelse return null;
        return std.fmt.parseUnsigned(usize, suffix[0..separator], 10) catch null;
    }

    fn openPalette(self: *App) !void {
        if (self.paletteVisible() or self.closeModalActive() or self.rename_tab_id != null or
            self.ui_key_state.len != 0 or self.terminal_key_state.len != 0 or
            self.ui_pointer_owned or self.scratchpad_ui_pointer_owned or
            self.scratchpad_terminal_pointer_owned or self.terminal_pointer_presses != 0 or
            self.scratchpad_escape_owned) return;
        const canvas = self.ui_canvas.bounds();
        if (canvas.width < 20 or canvas.height < 5) return;
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        try self.window.stopTextInput();
        clearPaletteInput(&self.palette_query);
        clearPaletteInput(&self.palette_argument);
        self.palette_model.refresh("");
        self.palette_model.selectFirst();
        self.palette_step = .commands;
        self.ui_tree.clearFocus();
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "palette.query" })) try self.composeUi();
        try self.syncTextInput();
        self.invalidateUi();
    }

    fn closePalette(self: *App, clear_inputs: bool) !void {
        if (!self.paletteVisible()) return;
        self.composition.cancel();
        _ = takeCommittedText(&self.pending_committed_text);
        self.palette_step = .closed;
        self.ui_tree.clearFocus();
        if (clear_inputs) {
            clearPaletteInput(&self.palette_query);
            clearPaletteInput(&self.palette_argument);
            self.palette_model.refresh("");
        }
        try self.composeUi();
        try self.syncTextInput();
        self.invalidateUi();
    }

    fn beginPaletteArgument(self: *App, definition_index: usize) !void {
        const definitions = self.actions.definitions();
        if (definition_index >= definitions.len) return;
        const command = definitions[definition_index].palette orelse return;
        switch (command.argument) {
            .none => try self.runPaletteAction(definition_index, null),
            .input => {
                self.composition.cancel();
                clearPaletteInput(&self.palette_argument);
                self.palette_step = .{ .input = definition_index };
                self.ui_tree.clearFocus();
                try self.composeUi();
                if (self.ui_tree.focus(.{ .value = "palette.argument" })) try self.composeUi();
                try self.syncTextInput();
                self.invalidateUi();
            },
            .choices => |choice_argument| {
                if (choice_argument.values.len == 0) return;
                self.composition.cancel();
                try self.window.stopTextInput();
                self.palette_step = .{ .choices = .{
                    .definition_index = definition_index,
                    .selected = 0,
                } };
                self.ui_tree.clearFocus();
                try self.composeUi();
                self.invalidateUi();
            },
        }
    }

    fn runPaletteAction(self: *App, definition_index: usize, value: ?[]const u8) !void {
        const definitions = self.actions.definitions();
        if (definition_index >= definitions.len) return;
        const definition = &definitions[definition_index];
        const command = definition.palette orelse return;
        var arguments: [1]inputmod.Argument = undefined;
        var invocation_arguments: []const inputmod.Argument = &.{};
        switch (command.argument) {
            .none => if (value != null) return,
            .input => |input_argument| {
                const supplied = std.mem.trim(u8, value orelse return, std.ascii.whitespace[0..]);
                if (supplied.len == 0) return;
                arguments[0] = .{ .name = input_argument.name, .value = supplied };
                invocation_arguments = arguments[0..1];
            },
            .choices => |choice_argument| {
                const supplied = value orelse return;
                arguments[0] = .{ .name = choice_argument.name, .value = supplied };
                invocation_arguments = arguments[0..1];
            },
        }

        // Keep Input bytes alive through invocation, but remove the modal
        // before a command composes its own UI (for example Rename tab).
        try self.closePalette(false);
        try self.dispatchAction(definition.name, .{
            .source = .palette,
            .arguments = invocation_arguments,
        });
        clearPaletteInput(&self.palette_query);
        clearPaletteInput(&self.palette_argument);
        self.palette_model.refresh("");
    }

    fn activatePalette(self: *App, origin: ?ui.Id) !void {
        switch (self.palette_step) {
            .closed => {},
            .commands => {
                const definition_index = if (origin) |id|
                    paletteSemanticIndex(id.value, "palette.action.") orelse
                        self.palette_model.selectedDefinitionIndex() orelse return
                else
                    self.palette_model.selectedDefinitionIndex() orelse return;
                try self.beginPaletteArgument(definition_index);
            },
            .input => |definition_index| {
                try self.runPaletteAction(definition_index, self.palette_argument.text());
            },
            .choices => |step| {
                const definition = &self.actions.definitions()[step.definition_index];
                const values = switch (definition.palette.?.argument) {
                    .choices => |choice_argument| choice_argument.values,
                    else => return,
                };
                const choice_index = if (origin) |id|
                    paletteChoiceSemanticIndex(id.value, step.definition_index) orelse step.selected
                else
                    step.selected;
                if (choice_index >= values.len) return;
                try self.runPaletteAction(step.definition_index, values[choice_index].value);
            },
        }
    }

    fn movePaletteSelection(self: *App, next: bool) !void {
        switch (self.palette_step) {
            .commands => {
                if (next) self.palette_model.selectNext() else self.palette_model.selectPrevious();
                try self.refreshActiveUi();
            },
            .choices => |step| {
                const definition = &self.actions.definitions()[step.definition_index];
                const values = switch (definition.palette.?.argument) {
                    .choices => |choice_argument| choice_argument.values,
                    else => return,
                };
                if (values.len == 0) return;
                const selected = if (next)
                    (step.selected + 1) % values.len
                else if (step.selected == 0)
                    values.len - 1
                else
                    step.selected - 1;
                self.palette_step = .{ .choices = .{
                    .definition_index = step.definition_index,
                    .selected = selected,
                } };
                try self.refreshActiveUi();
            },
            .closed, .input => {},
        }
    }

    fn paletteOpenAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.openPalette();
    }

    fn paletteActivateAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        try self.activatePalette(invocation.origin);
    }

    fn searchOpenAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.openSearch();
    }

    fn terminalContextMenuAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.openContextMenuAtCursor();
    }

    fn searchCloseAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.closeSearch();
    }

    fn searchNextAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.moveSearchSelection(true);
    }

    fn searchPreviousAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        try self.moveSearchSelection(false);
    }

    fn searchCaseAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (!self.search_visible) try self.openSearch();
        self.search_case = if (self.search_case == .sensitive) .ascii_insensitive else .sensitive;
        self.restartSearch();
        try self.refreshActiveUi();
    }

    fn searchRegexAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        _ = invocation;
        const self: *App = @ptrCast(@alignCast(context));
        if (!self.search_visible) try self.openSearch();
        self.search_mode = if (self.search_mode == .literal) .regex else .literal;
        self.restartSearch();
        try self.refreshActiveUi();
    }

    fn searchActivateMatchAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const origin = invocation.origin orelse return;
        const index = searchMatchSemanticIndex(origin.value) orelse return;
        if (index >= self.search_match_count) return;
        self.search_active_index = index;
        _ = self.revealActiveSearchMatch();
        try self.composeUi();
        if (self.ui_tree.focus(.{ .value = "search.query" })) try self.composeUi();
        self.invalidateUi();
    }

    fn uiTestActivateAction(context: *anyopaque, invocation: inputmod.Invocation) anyerror!void {
        const self: *App = @ptrCast(@alignCast(context));
        const fixture = self.ui_test orelse return error.UiTestFixtureUnavailable;
        fixture.recordDispatch(invocation);
    }

    fn routeFocusedUiKey(
        self: *App,
        raw: platform.KeyEvent,
        translated: inputmod.Press,
    ) !bool {
        if (try self.routeOwnedUiKey(raw)) return true;
        const identity = uiKeyIdentity(raw) orelse return false;
        if (raw.action != .press) return false;

        const plan = self.planFocusedUiKey(raw, translated) orelse return false;
        if (!self.ui_key_state.claim(identity, plan.repeat())) return false;
        try self.executeUiKeyPlan(plan);
        return true;
    }

    fn routeOwnedUiKey(self: *App, raw: platform.KeyEvent) !bool {
        const identity = uiKeyIdentity(raw) orelse return false;
        if (self.ui_key_state.indexOf(identity)) |owned_index| {
            switch (raw.action) {
                .press => {},
                .repeat => try self.executeUiRepeat(self.ui_key_state.storage[owned_index].repeat),
                .release => self.ui_key_state.release(owned_index),
            }
            return true;
        }
        return false;
    }

    /// Decide without mutating focus, Input, or the action registry. The caller
    /// records transition ownership before executing this plan, so a full
    /// storage array safely falls through to the terminal without half-owning
    /// the gesture.
    fn planFocusedUiKey(
        self: *App,
        raw: platform.KeyEvent,
        translated: inputmod.Press,
    ) ?UiKeyPlan {
        const tree = self.activeUiTree();
        const intent = translated.intent orelse return if (self.closeModalActive() or self.paletteVisible() or
            self.contextMenuVisible()) .consume else null;
        const no_command = !raw.mods.ctrl and !raw.mods.alt and !raw.mods.super;

        // The context menu is modal: its four navigation keys move, activate
        // or close it, and every other key is swallowed rather than reaching
        // the terminal it floats over.
        if (self.contextMenuVisible()) {
            if (no_command) switch (intent.key) {
                .named => |named| switch (named) {
                    .escape => return .context_menu_close,
                    .tab => return .{ .context_menu_move = !raw.mods.shift },
                    .up => return .{ .context_menu_move = false },
                    .down => return .{ .context_menu_move = true },
                    .enter => return .context_menu_activate,
                    else => {},
                },
                .character => {},
            };
            return .consume;
        }

        if (self.paletteVisible() and no_command) switch (intent.key) {
            .named => |named| switch (named) {
                .escape => return .palette_close,
                .tab => return .{ .palette_move = !raw.mods.shift },
                .up => return .{ .palette_move = false },
                .down => return .{ .palette_move = true },
                .enter => return .palette_activate,
                else => {},
            },
            .character => {},
        };

        if (!self.closeModalActive() and !self.paletteVisible() and no_command) {
            if (tree.focusedElement()) |focused| {
                if (std.mem.eql(u8, focused.role, "workspace")) switch (intent.key) {
                    .named => |named| switch (named) {
                        .up => return .{ .workspace_focus = false },
                        .down => return .{ .workspace_focus = true },
                        else => {},
                    },
                    .character => {},
                };
            }
        }

        const is_escape = switch (intent.key) {
            .named => |named| named == .escape,
            .character => false,
        };
        if (is_escape and no_command) {
            if (self.pending_close_workspace != null) return .{ .activate = .{
                .id = .{ .value = "workspace-close.cancel" },
                .action = workspace_close_cancel_action,
            } };
            if (self.closeModalActive()) return .{ .activate = .{
                .id = .{ .value = "tab-close.cancel" },
                .action = tab_close_cancel_action,
            } };
            if (self.rename_tab_id != null) {
                const rename_semantic = tabRenameSemanticId(
                    &self.tab_rename_semantic_storage,
                    self.activePresentation().key,
                ) catch return .consume;
                return .{ .activate = .{
                    .id = .{ .value = rename_semantic },
                    .action = tab_rename_cancel_action,
                } };
            }
        }

        const is_tab = switch (intent.key) {
            .named => |named| named == .tab,
            .character => false,
        };
        if (is_tab and no_command) {
            if (self.closeModalActive()) {
                const cancel_id = if (self.pending_close_workspace != null) "workspace-close.cancel" else "tab-close.cancel";
                const confirm_id = if (self.pending_close_workspace != null) "workspace-close.confirm" else "tab-close.confirm";
                const focused_id = if (tree.focusedElement()) |focused| focused.id.value else "";
                const target = if (raw.mods.shift)
                    if (std.mem.eql(u8, focused_id, cancel_id)) confirm_id else cancel_id
                else if (std.mem.eql(u8, focused_id, confirm_id))
                    cancel_id
                else
                    confirm_id;
                return .{ .focus_id = .{ .value = target } };
            }
            // Tab is terminal input until a user explicitly focuses Conduit
            // UI. Merely having a visible sidebar must never steal it.
            _ = tree.focusedElement() orelse return null;
            return .{ .focus = raw.mods.shift };
        }

        const is_enter = switch (intent.key) {
            .named => |named| named == .enter,
            .character => false,
        };
        if (is_enter and no_command) {
            const activation = tree.activateFocused() orelse return if (self.closeModalActive()) .consume else null;
            if (self.closeModalActive()) {
                const cancel_id = if (self.pending_close_workspace != null) "workspace-close.cancel" else "tab-close.cancel";
                const confirm_id = if (self.pending_close_workspace != null) "workspace-close.confirm" else "tab-close.confirm";
                if (!std.mem.eql(u8, activation.id.value, cancel_id) and
                    !std.mem.eql(u8, activation.id.value, confirm_id)) return .consume;
            }
            return .{ .activate = activation };
        }

        // A close prompt is modal. Unrelated keys are deliberately swallowed
        // rather than becoming input to the process it is protecting.
        if (self.closeModalActive()) return .consume;

        _ = tree.focusedInput() orelse return if (self.paletteVisible()) .consume else null;
        const origin = (tree.focusedElement() orelse return null).id;
        const native_command = switch (self.binding_profile) {
            .macos => raw.mods.super and !raw.mods.ctrl and !raw.mods.alt and !raw.mods.shift,
            .linux_windows => raw.mods.ctrl and !raw.mods.super and !raw.mods.alt and !raw.mods.shift,
        };
        const letter = raw.unshifted_codepoint;
        if (native_command and (letter == 'a' or letter == 'A' or
            letter == 'c' or letter == 'C' or letter == 'v' or letter == 'V'))
        {
            return switch (letter) {
                'a', 'A' => .{ .select_all = origin },
                'c', 'C' => .{ .copy = origin },
                'v', 'V' => .{ .paste = origin },
                else => unreachable,
            };
        }

        const edit_plan: ?UiKeyPlan = switch (intent.key) {
            .character => if (intent.text() != null and translated.encoded.text.len != 0)
                .{ .text = .{ .origin = origin, .value = UiKeyText.copy(translated.encoded.text) } }
            else
                null,
            .named => |named| if (raw.mods.ctrl or raw.mods.alt or raw.mods.super)
                null
            else switch (named) {
                .left => .{ .edit = .{ .origin = origin, .operation = .previous, .extend = raw.mods.shift } },
                .right => .{ .edit = .{ .origin = origin, .operation = .next, .extend = raw.mods.shift } },
                .home => .{ .edit = .{ .origin = origin, .operation = .home, .extend = raw.mods.shift } },
                .end => .{ .edit = .{ .origin = origin, .operation = .end, .extend = raw.mods.shift } },
                .backspace => .{ .edit = .{ .origin = origin, .operation = .backspace, .extend = false } },
                .delete => .{ .edit = .{ .origin = origin, .operation = .delete, .extend = false } },
                else => null,
            },
        };
        return edit_plan orelse if (self.paletteVisible()) .consume else null;
    }

    fn executeUiKeyPlan(self: *App, plan: UiKeyPlan) !void {
        switch (plan) {
            .consume => {},
            .focus => |backwards| {
                const focused = if (backwards)
                    self.activeUiTree().focusPrevious()
                else
                    self.activeUiTree().focusNext();
                if (focused != null) try self.refreshActiveUi();
            },
            .focus_id => |id| {
                if (self.activeUiTree().focus(id)) try self.refreshActiveUi();
            },
            .workspace_focus => |next| try self.moveWorkspaceFocus(next),
            .activate => |activation| try self.dispatchAction(activation.action, .{
                .source = .keybinding,
                .origin = activation.id,
            }),
            .palette_close => try self.closePalette(true),
            .palette_move => |next| try self.movePaletteSelection(next),
            .context_menu_close => try self.closeContextMenu(),
            .context_menu_move => |next| try self.moveContextMenuFocus(next),
            .context_menu_activate => {
                const activation = self.activeUiTree().activateFocused() orelse return;
                try self.activateContextMenuItem(activation, .keybinding);
            },
            .palette_activate => try self.dispatchAction(palette_activate_action, .{
                .source = .keybinding,
                .origin = if (self.activeUiTree().focusedElement()) |element| element.id else null,
            }),
            .select_all => |origin| {
                const field = self.focusedInputAt(origin) orelse return;
                const before = field.selection();
                field.selectAll();
                if (!std.meta.eql(before, field.selection())) try self.refreshActiveUi();
            },
            .copy => |origin| try self.dispatchAction(clipboard_copy_action, .{
                .source = .keybinding,
                .origin = origin,
            }),
            .paste => |origin| try self.dispatchAction(clipboard_paste_action, .{
                .source = .keybinding,
                .origin = origin,
            }),
            .text => |text| try self.editFocusedInput(text.origin, .{ .text = text }),
            .edit => |edit| try self.editFocusedInput(edit.origin, .{ .edit = edit }),
        }
    }

    fn executeUiRepeat(self: *App, repeat: UiKeyRepeat) !void {
        switch (repeat) {
            .none => {},
            .text => |text| try self.editFocusedInput(text.origin, .{ .text = text }),
            .edit => |edit| try self.editFocusedInput(edit.origin, .{ .edit = edit }),
        }
    }

    fn focusedInputAt(self: *App, origin: ui.Id) ?*ui.Input {
        const tree = self.activeUiTree();
        const focused = tree.focusedElement() orelse return null;
        if (!std.mem.eql(u8, focused.id.value, origin.value)) return null;
        return tree.focusedInput();
    }

    fn editFocusedInput(self: *App, origin: ui.Id, repeat: UiKeyRepeat) !void {
        const field = self.focusedInputAt(origin) orelse return;
        const before_cursor = field.cursorByte();
        const before_anchor = field.anchorByte();
        const before_len = field.text().len;
        switch (repeat) {
            .none => return,
            .text => |text| field.insert(text.value.slice()) catch |err| {
                log.warn("typed input of {d} byte(s) rejected: {s}", .{ text.value.len, @errorName(err) });
                return;
            },
            .edit => |edit| switch (edit.operation) {
                .previous => field.movePrevious(edit.extend),
                .next => field.moveNext(edit.extend),
                .home => field.moveHome(edit.extend),
                .end => field.moveEnd(edit.extend),
                .backspace => field.backspace(),
                .delete => field.delete(),
            },
        }
        if (field.cursorByte() != before_cursor or field.anchorByte() != before_anchor or
            field.text().len != before_len)
        {
            if (field == &self.palette_query and self.palette_step == .commands) {
                self.palette_model.refresh(field.text());
            }
            if (field == &self.search_query and self.search_visible) self.restartSearch();
            try self.refreshActiveUi();
        }
    }

    /// Queue bytes an input event produced behind any already waiting.
    ///
    /// More than one event can land between two frames, and the second must
    /// not overwrite the first. A buffer that is full drops the newest and
    /// says how many bytes, never which.
    fn stageForChild(self: *App, bytes: []const u8) void {
        if (!appendChildInput(&self.child_input, bytes)) {
            log.warn("{d} byte(s) of input dropped: {d} already waiting for the child", .{ bytes.len, self.child_input.len });
        }
    }

    /// Copy the selection to `location`, and return how many bytes went.
    fn copySelectionTo(self: *App, location: ClipboardTarget) CopyError!usize {
        const text = (try self.presentedLive().terminal().selectionText(self.allocator)) orelse return error.NothingSelected;
        defer self.allocator.free(text);
        switch (location) {
            .standard => try platform.setClipboardText(self.allocator, text),
            .primary => try platform.setPrimarySelectionText(self.allocator, text),
        }
        return text.len;
    }

    /// Paste `location` into the program, and log what happened by size.
    fn paste(self: *App, location: ClipboardTarget) void {
        self.pasteToTerminal(location) catch |err| {
            log.warn("paste from the {s} clipboard failed: {s}", .{ @tagName(location), @errorName(err) });
        };
    }

    fn pasteToTerminal(self: *App, location: ClipboardTarget) PasteFailure!void {
        const outcome = try self.preparePasteFrom(location);
        switch (outcome) {
            .queued => |bytes| log.info("pasted {d} byte(s) from the {s} clipboard{s}", .{
                bytes,
                @tagName(location),
                if (self.presentedLive().terminal().bracketedPasteEnabled()) ", bracketed" else "",
            }),
            // A multi-line paste into a program that did not ask for bracketed
            // paste could run every line as a command. M1 has no prompt to
            // confirm it with, so nothing is sent; the size is logged so the
            // refusal is visible, and the text is not.
            .confirmation_required => |bytes| log.warn(
                "paste of {d} byte(s) from the {s} clipboard not sent: it has more than one line and the program did not enable bracketed paste; there is no confirmation prompt yet",
                .{ bytes, @tagName(location) },
            ),
        }
    }

    /// Read `location`, encode it for the program's paste mode, and queue it
    /// for `pumpChild`. Sends nothing when the encoder wants confirmation.
    fn preparePasteFrom(self: *App, location: ClipboardTarget) PasteFailure!PasteOutcome {
        if (self.pending_paste != null) return error.PasteInFlight;
        const text = switch (location) {
            .standard => try platform.getClipboardText(self.allocator),
            .primary => try platform.getPrimarySelectionText(self.allocator),
        };
        defer self.allocator.free(text);
        // `false`: nobody confirmed anything, because there is nothing to
        // confirm with yet (M1).
        const prepared = try self.presentedLive().terminal().preparePaste(self.allocator, text, false);
        switch (prepared) {
            .confirmation_required => return .{ .confirmation_required = text.len },
            .encoded => |bytes| {
                self.pending_paste = bytes;
                return .{ .queued = bytes.len };
            },
        }
    }

    /// Act on one pointer motion event.
    ///
    /// Motion is only interesting to the user while a drag is in progress;
    /// everything else is a program's business, and the terminal decides which.
    fn onPointerMotion(self: *App, motion: platform.PointerMotion) !void {
        const presented = self.presentedLive();
        const geometry = self.pointerGeometry();
        var terminal_motion = motion;
        terminal_motion.x = clippedPaneCoordinate(
            terminal_motion.x * self.window.state.scale.factor - @as(f32, @floatFromInt(self.terminalOriginPixels())),
            geometry.surface_width_px,
        );
        terminal_motion.y = clippedPaneCoordinate(
            terminal_motion.y * self.window.state.scale.factor - @as(f32, @floatFromInt(self.terminalOriginYPixels())),
            geometry.surface_height_px,
        );
        const event = inputmod.pointerMotion(&geometry, terminal_motion);
        self.last_pointer = event.pointer;
        const outcome = presented.terminal().pointerEvent(
            event,
            clickStamp(self.io),
            &self.child_input,
        );
        switch (outcome) {
            .ignored => {},
            .selection => self.scheduler.invalidate(),
            .reported => |sent| log.info("pointer motion: {d} byte(s) to the program", .{sent}),
        }
    }

    /// Keep the autoscroll going for a drag that has reached past the edge of
    /// the window, called once per tick by the event loop.
    ///
    /// Returns whether the viewport moved, which is also whether a frame is
    /// owed. A drag that is not at an edge does nothing and says so, which is
    /// how the loop knows to stop asking.
    fn onSelectionAutoscroll(self: *App) bool {
        const presented = self.presentedLive();
        if (presented.terminal().selectionAutoscrollDirection() == null) return false;
        // The pointer position is the last one the OS reported, which is the one
        // that is past the edge: there is no newer event, because the pointer
        // has stopped moving and is sitting outside the window.
        const before = presented.terminal().viewport().offset;
        if (!presented.terminal().selectionAutoscroll(self.last_pointer)) return false;
        if (presented.terminal().viewport().offset == before) return false;
        self.scheduler.invalidate();
        return true;
    }

    /// The instant a click happened, for the gesture's double-click counting.
    ///
    /// The real monotonic clock, not a frame counter: the gesture asks "were these
    /// two presses within half a second of each other", and only a clock answers
    /// that. `std.Io.Timestamp` is what upstream's gesture takes, so this is a
    /// narrowing from the app's `i128` nanoseconds and nothing more.
    fn clickStamp(io: Io) ?std.Io.Timestamp {
        return .{ .nanoseconds = @intCast(Io.Clock.real.now(io).nanoseconds) };
    }

    /// Everything outside the window's event queue that can make the screen
    /// wrong: a finished job, the child's output, and the cursor's blink.
    fn poll(self: *App) bool {
        var changed = self.pollLoad();
        changed = self.advanceSearch() or changed;
        changed = self.pollScratchpadLoad() or changed;
        changed = self.finalizeClosingPresentations() or changed;
        if (self.workspace_registry.count() == 0) return changed;
        for (self.workspace_presentations.items) |presentation| {
            const model = self.workspace_registry.byKey(presentation.key) orelse continue;
            if (model.needsPump()) changed = true;
        }
        if (self.activeLive().child()) |child| {
            switch (child.state()) {
                .running => {},
                .exited => |status| {
                    if (!self.exit_logged) {
                        self.exit_logged = true;
                        switch (status) {
                            .code => |code| log.info("child exited with status {d}", .{code}),
                            .signal => |name| log.info("child ended by {s}", .{@tagName(name)}),
                            // An end the backend does not model is still an end,
                            // and still ends the run.
                            .unknown => log.info("child ended in a way this backend does not model", .{}),
                        }
                        changed = true;
                    }
                },
            }
        }
        const phase = self.blinkPhase();
        // A drag that has reached past the edge of the window keeps growing
        // while it is held. The tick comes from the loop rather than from a
        // timer of its own: the loop already wakes at `idle_tick_ms` whenever
        // there is a child or a blinking cursor, which is every case where a
        // drag is in progress over a program's output. A dedicated timer would
        // be the better shape and is not built here because nothing in this
        // task can prove it — see TASK-14's report.
        if (self.onSelectionAutoscroll()) changed = true;
        if (phase != self.blink_visible) {
            self.blink_visible = phase;
            changed = true;
        }
        return changed;
    }

    /// Whether the cursor is on a blink cycle, which is the only reason a run
    /// with no child and no window events has a deadline at all.
    fn cursorBlinks(self: *const App) bool {
        const state = self.presentedLiveConst().terminalConst().cursor();
        return state.blinking and state.visible and state.position != null;
    }

    /// The cursor's blink phase: whether it should be drawn this instant.
    ///
    /// A square wave of the clock rather than a counter a frame ticks, so a
    /// frame that arrives late shows the phase the time says it is rather than
    /// the phase a frame counter would have drifted to.
    fn blinkPhase(self: *const App) bool {
        if (!self.cursorBlinks()) return true;
        const now = Io.Clock.real.now(self.io).nanoseconds;
        return @mod(now - self.blink_epoch_ns, 2 * blink_period_ns) < blink_period_ns;
    }

    /// Whether this run should end because the program it was waiting for has.
    fn childGone(self: *const App) bool {
        if (!self.exit_with_child or !self.spawn_finished) return false;
        const live = self.activeLiveConst();
        // A tab created in command mode has no child until its worker returns;
        // leaving then would abandon the spawn the user just asked for.
        const child = live.child() orelse return self.activePresentationConst().load == null;
        return switch (child.state()) {
            .running => false,
            // The PTY backend can observe exit before its read queue has been
            // consumed. Session needs one final zero-byte drain to prove the
            // queue is empty, so command mode must not leave sooner.
            .exited => !live.needsPump(),
        };
    }

    /// Project the test fixture when attached, otherwise the reusable live UI
    /// layer that carries the input method's preedit.
    fn overlayView(self: *App) render.OverlayView {
        if (self.ui_test) |fixture| return fixture.view();
        return self.ui_canvas.view(&default_palette);
    }

    /// One UI mutation invalidates both layers and schedules exactly one frame.
    fn invalidateUi(self: *App) void {
        self.overlay_grid.invalidateCanvasOverlay();
        self.scheduler.invalidate();
    }

    fn activeUiTree(self: *App) *ui.Tree {
        if (self.ui_test) |fixture| return &fixture.tree;
        return &self.ui_tree;
    }

    fn refreshActiveUi(self: *App) !void {
        if (self.ui_test) |fixture| {
            try fixture.rerender();
        } else {
            try self.composeUi();
        }
        self.invalidateUi();
    }

    fn respondDriverResult(
        self: *App,
        token: u64,
        id: testdriver.RequestId,
        result: testdriver.Result,
    ) void {
        const driver = self.driver orelse return;
        var encoded = testdriver.encodeSuccess(self.allocator, id, result) catch |err| {
            log.warn("test-driver response encoding failed: {s}", .{@errorName(err)});
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            return;
        };
        defer encoded.deinit();
        driver.respond(token, encoded.bytes) catch |err| {
            log.warn("test-driver response delivery failed: {s}", .{@errorName(err)});
        };
    }

    fn respondDriverFault(
        self: *App,
        token: u64,
        id: ?testdriver.RequestId,
        fault: testdriver.Fault,
    ) void {
        const driver = self.driver orelse return;
        var encoded = testdriver.encodeFailure(self.allocator, id, fault) catch |err| {
            log.warn("test-driver error encoding failed: {s}", .{@errorName(err)});
            return;
        };
        defer encoded.deinit();
        driver.respond(token, encoded.bytes) catch |err| {
            log.warn("test-driver error delivery failed: {s}", .{@errorName(err)});
        };
    }

    fn nextDriverBarrier(self: *App) u32 {
        while (true) {
            const candidate = self.next_driver_barrier;
            self.next_driver_barrier +%= 1;
            if (self.next_driver_barrier == 0) self.next_driver_barrier = 1;
            if (candidate == 0) continue;
            var used = false;
            for (self.driver_pending) |slot| {
                const pending = slot orelse continue;
                switch (pending.state) {
                    .barrier => |barrier| if (barrier.id == candidate) {
                        used = true;
                        break;
                    },
                    .wait, .screenshot => {},
                }
            }
            if (!used) return candidate;
        }
    }

    fn addDriverPending(self: *App, pending: DriverPending) ?usize {
        for (&self.driver_pending, 0..) |*slot, index| {
            if (slot.* == null) {
                slot.* = pending;
                return index;
            }
        }
        return null;
    }

    fn takeDriverPending(self: *App, index: usize) DriverPending {
        const pending = self.driver_pending[index].?;
        self.driver_pending[index] = null;
        return pending;
    }

    fn finishDriverBarrier(self: *App, barrier_id: u32) void {
        for (&self.driver_pending, 0..) |*slot, index| {
            const pending = slot.* orelse continue;
            const matches = switch (pending.state) {
                .barrier => |barrier| barrier.id == barrier_id,
                .wait, .screenshot => false,
            };
            if (!matches) continue;
            var completed = self.takeDriverPending(index);
            defer completed.deinit(self.allocator);
            const request = switch (completed.parsed.outcome) {
                .request => |request| request,
                .failure => return,
            };
            self.respondDriverResult(completed.token, request.id, .ok);
            return;
        }
        log.warn("test-driver received an unknown input barrier", .{});
    }

    fn driverTargetPoint(self: *App, target: testdriver.Target) ?testdriver.LogicalPoint {
        return switch (target) {
            .point => |point| point,
            .id => |id| point: {
                const element = self.activeUiTree().byId(id) orelse return null;
                if (element.bounds.isEmpty()) return null;
                const scale = @as(f64, self.window.state.scale.factor);
                break :point .{
                    .x = (@as(f64, @floatFromInt(element.bounds.x)) +
                        @as(f64, @floatFromInt(element.bounds.width)) / 2.0) / scale,
                    .y = (@as(f64, @floatFromInt(element.bounds.y)) +
                        @as(f64, @floatFromInt(element.bounds.height)) / 2.0) / scale,
                };
            },
        };
    }

    fn postDriverClick(self: *App, target: testdriver.Target, mods: platform.Mods) !void {
        const point = self.driverTargetPoint(target) orelse return error.DriverTargetNotFound;
        const x: f32 = @floatCast(point.x);
        const y: f32 = @floatCast(point.y);
        try self.window.postPointerButton(.{ .button = .left, .action = .press, .mods = mods, .x = x, .y = y });
        try self.window.postPointerButton(.{ .button = .left, .action = .release, .mods = mods, .x = x, .y = y });
    }

    fn postDriverDrag(self: *App, from: testdriver.Target, to: testdriver.Target) !void {
        const start = self.driverTargetPoint(from) orelse return error.DriverTargetNotFound;
        const finish = self.driverTargetPoint(to) orelse return error.DriverTargetNotFound;
        try self.window.postPointerButton(.{
            .button = .left,
            .action = .press,
            .x = @floatCast(start.x),
            .y = @floatCast(start.y),
        });
        try self.window.postPointerMotion(.{
            .buttons = .{ .left = true },
            .x = @floatCast(finish.x),
            .y = @floatCast(finish.y),
        });
        try self.window.postPointerButton(.{
            .button = .left,
            .action = .release,
            .x = @floatCast(finish.x),
            .y = @floatCast(finish.y),
        });
    }

    fn postDriverKey(self: *App, chord: testdriver.KeyChord) !void {
        const mods: platform.Mods = .{
            .ctrl = chord.modifiers.ctrl,
            .alt = chord.modifiers.alt,
            .shift = chord.modifiers.shift,
            .super = chord.modifiers.super,
        };
        switch (chord.key) {
            .character => |codepoint| {
                try self.window.postCharacterKey(codepoint, mods, .press);
                try self.window.postCharacterKey(codepoint, mods, .release);
            },
            .named => |named| {
                const key: platform.Key = switch (named) {
                    .enter => .enter,
                    .tab => .tab,
                    .backspace => .backspace,
                    .escape => .escape,
                    .insert => .insert,
                    .delete => .delete,
                    .up => .up,
                    .down => .down,
                    .left => .left,
                    .right => .right,
                    .home => .home,
                    .end => .end,
                    .page_up => .page_up,
                    .page_down => .page_down,
                    .f1 => .f1,
                    .f2 => .f2,
                    .f3 => .f3,
                    .f4 => .f4,
                    .f5 => .f5,
                    .f6 => .f6,
                    .f7 => .f7,
                    .f8 => .f8,
                    .f9 => .f9,
                    .f10 => .f10,
                    .f11 => .f11,
                    .f12 => .f12,
                };
                try self.window.postNamedKey(key, mods, .press);
                try self.window.postNamedKey(key, mods, .release);
            },
        }
    }

    fn postDriverEvents(self: *App, index: usize, params: testdriver.Params) !void {
        switch (params) {
            .click => |target| try self.postDriverClick(target, .{}),
            .ctrl_click => |target| try self.postDriverClick(target, switch (self.binding_profile) {
                .macos => .{ .super = true },
                .linux_windows => .{ .ctrl = true },
            }),
            .double_click => |target| {
                try self.postDriverClick(target, .{});
                try self.postDriverClick(target, .{});
            },
            .right_click => |target| {
                const point = self.driverTargetPoint(target) orelse return error.DriverTargetNotFound;
                const x: f32 = @floatCast(point.x);
                const y: f32 = @floatCast(point.y);
                try self.window.postPointerButton(.{ .button = .right, .action = .press, .x = x, .y = y });
                try self.window.postPointerButton(.{ .button = .right, .action = .release, .x = x, .y = y });
            },
            .drag => |drag| try self.postDriverDrag(drag.from, drag.to),
            .key => |key| try self.postDriverKey(key.chord),
            .type => |typed| {
                const text = try self.allocator.dupeZ(u8, typed.text);
                self.driver_pending[index].?.text = text;
                try self.window.postTextInput(text);
            },
            .scroll => |scroll| {
                const point: testdriver.LogicalPoint = scroll.point orelse .{
                    .x = @as(f64, @floatFromInt(self.window.state.logical.width)) / 2.0,
                    .y = @as(f64, @floatFromInt(self.window.state.logical.height)) / 2.0,
                };
                try self.window.postWheel(.{
                    .dx = @floatCast(scroll.dx),
                    .dy = @floatCast(scroll.dy),
                    .x = @floatCast(point.x),
                    .y = @floatCast(point.y),
                });
            },
            else => return error.NotAnInputMethod,
        }
    }

    fn driverInspectJson(self: *App) ![]u8 {
        const bytes = try self.allocator.alloc(u8, testdriver.max_response_bytes - 1024);
        errdefer self.allocator.free(bytes);
        var writer = Writer.fixed(bytes);
        try self.activeUiTree().writeJson(&writer);
        return try self.allocator.realloc(bytes, writer.buffered().len);
    }

    fn driverTerminal(self: *App, target: testdriver.TerminalTarget) ?*session.Session {
        return switch (target) {
            .active => self.presentedLive(),
            .scratchpad => self.scratchpadLive(),
        };
    }

    fn driverTerminalText(self: *App, target: testdriver.TerminalTarget) ![]u8 {
        const live = self.driverTerminal(target) orelse return error.SessionNotFound;
        try live.terminal().refresh(self.allocator);
        const bytes = try self.allocator.alloc(u8, testdriver.max_response_bytes - 1024);
        errdefer self.allocator.free(bytes);
        var writer = Writer.fixed(bytes);
        try live.terminal().writeVisibleText(&writer);
        return try self.allocator.realloc(bytes, writer.buffered().len);
    }

    fn driverLogs(self: *App, requested: ?usize) ![]u8 {
        const capacity = @min(requested orelse log_tail_capacity, log_tail_capacity);
        var bytes = try self.allocator.alloc(u8, capacity);
        errdefer self.allocator.free(bytes);
        const tail = sink.copyTail(bytes);
        if (tail.ptr != bytes.ptr) std.mem.copyForwards(u8, bytes[0..tail.len], tail);
        return try self.allocator.realloc(bytes, tail.len);
    }

    fn driverConditionMet(self: *App, condition: testdriver.WaitCondition) !bool {
        return switch (condition) {
            .element => |wanted| condition_met: {
                const element = self.activeUiTree().byId(wanted.id);
                const actual = switch (wanted.state) {
                    .exists => element != null,
                    .hovered => if (element) |value| value.state.hovered else false,
                    .focused => if (element) |value| value.state.focused else false,
                    .pressed => if (element) |value| value.state.pressed else false,
                };
                break :condition_met actual == wanted.equals;
            },
            .terminal_text => |wanted| terminal: {
                const live = self.driverTerminal(wanted.target) orelse break :terminal false;
                try live.terminal().refresh(self.allocator);
                break :terminal live.terminal().visibleTextContains(wanted.contains);
            },
        };
    }

    fn driverScreenshotInFlight(self: *const App) bool {
        for (self.driver_pending) |slot| {
            const pending = slot orelse continue;
            switch (pending.state) {
                .screenshot => return true,
                else => {},
            }
        }
        return false;
    }

    /// Force the shared surface current, copy its pixels, and hand compression
    /// and persistence to one bounded worker job. The parsed request stays
    /// alive until that worker reports completion.
    fn retainDriverScreenshot(
        self: *App,
        token: u64,
        parsed: testdriver.ParsedRequest,
        id: testdriver.RequestId,
    ) bool {
        const artifact_dir = self.driver_artifact_dir orelse {
            self.respondDriverFault(token, id, testdriver.Fault.unavailable("Artifact directory unavailable"));
            return false;
        };
        if (self.driverScreenshotInFlight()) {
            self.respondDriverFault(token, id, testdriver.Fault.unavailable("Screenshot already in progress"));
            return false;
        }

        // Even an otherwise-idle grid is redrawn immediately so the capture
        // reflects all state at this request boundary, not an earlier frame.
        self.invalidateUi();
        self.needs_present = true;
        self.drawFrame() catch |err| {
            log.warn("test-driver could not draw a screenshot frame: {s}", .{@errorName(err)});
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            return false;
        };
        const captured = self.capture() catch |err| {
            log.warn("test-driver framebuffer readback failed: {s}", .{@errorName(err)});
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            return false;
        };
        const pixels = self.allocator.dupe(u8, captured) catch |err| {
            log.warn("test-driver screenshot copy failed: {s}", .{@errorName(err)});
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            return false;
        };

        const number = self.next_screenshot_number;
        self.next_screenshot_number +|= 1;
        const path = std.fmt.allocPrint(
            self.allocator,
            "{s}{c}screenshot-{d:0>4}.png",
            .{ artifact_dir, std.fs.path.sep, number },
        ) catch |err| {
            self.allocator.free(pixels);
            log.warn("test-driver screenshot path allocation failed: {s}", .{@errorName(err)});
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            return false;
        };

        const job = self.allocator.create(ScreenshotJob) catch |err| {
            self.allocator.free(path);
            self.allocator.free(pixels);
            log.warn("test-driver screenshot job allocation failed: {s}", .{@errorName(err)});
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            return false;
        };
        job.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .window = self.window,
            .path = path,
            .pixels = pixels,
            .size = self.size,
        };
        const index = self.addDriverPending(.{
            .token = token,
            .parsed = parsed,
            .state = .{ .screenshot = job },
        }) orelse {
            job.deinit();
            self.respondDriverFault(token, id, testdriver.Fault.unavailable("Driver queue full"));
            return false;
        };
        job.start() catch |err| {
            log.warn("test-driver screenshot worker could not start: {s}", .{@errorName(err)});
            var failed = self.takeDriverPending(index);
            self.respondDriverFault(token, id, testdriver.Fault.internal_error);
            failed.deinit(self.allocator);
            return true;
        };
        return true;
    }

    fn retainDriverInput(
        self: *App,
        token: u64,
        parsed: testdriver.ParsedRequest,
        params: testdriver.Params,
    ) bool {
        const barrier_id = self.nextDriverBarrier();
        const index = self.addDriverPending(.{
            .token = token,
            .parsed = parsed,
            .state = .{ .barrier = .{ .id = barrier_id, .posted = false } },
        }) orelse {
            const request = switch (parsed.outcome) {
                .request => |request| request,
                .failure => return false,
            };
            self.respondDriverFault(token, request.id, testdriver.Fault.unavailable("Driver queue full"));
            return false;
        };

        self.postDriverEvents(index, params) catch |err| {
            var failed = self.takeDriverPending(index);
            const request = switch (failed.parsed.outcome) {
                .request => |request| request,
                .failure => {
                    failed.deinit(self.allocator);
                    return true;
                },
            };
            self.respondDriverFault(token, request.id, if (err == error.DriverTargetNotFound)
                testdriver.Fault.notFound("Element not found")
            else
                testdriver.Fault.internal_error);
            failed.deinit(self.allocator);
            return true;
        };
        self.window.postDriverBarrier(barrier_id) catch |err| {
            log.warn("test-driver input barrier could not be posted yet: {s}", .{@errorName(err)});
            return true;
        };
        self.driver_pending[index].?.state.barrier.posted = true;
        return true;
    }

    fn executeDriverRequest(
        self: *App,
        token: u64,
        parsed: testdriver.ParsedRequest,
    ) bool {
        const request = switch (parsed.outcome) {
            .request => |request| request,
            .failure => return false,
        };
        if (!request.method.available()) {
            self.respondDriverFault(token, request.id, testdriver.Fault.unavailable("Method unavailable"));
            return false;
        }
        switch (request.params) {
            .inspect => {
                const semantic_json = self.driverInspectJson() catch |err| {
                    log.warn("test-driver inspect failed: {s}", .{@errorName(err)});
                    self.respondDriverFault(token, request.id, testdriver.Fault.internal_error);
                    return false;
                };
                defer self.allocator.free(semantic_json);
                self.respondDriverResult(token, request.id, .{ .inspect = .{ .semantic_json = semantic_json } });
                return false;
            },
            .click, .ctrl_click, .double_click, .right_click, .drag, .key, .type, .scroll => {
                return self.retainDriverInput(token, parsed, request.params);
            },
            .terminal_text => |terminal| {
                const text = self.driverTerminalText(terminal.target) catch |err| {
                    log.warn("test-driver terminal serialization failed: {s}", .{@errorName(err)});
                    self.respondDriverFault(token, request.id, testdriver.Fault.internal_error);
                    return false;
                };
                defer self.allocator.free(text);
                self.respondDriverResult(token, request.id, .{ .terminal_text = .{ .text = text } });
                return false;
            },
            .wait_for => |wait| {
                const matched = self.driverConditionMet(wait.condition) catch |err| {
                    log.warn("test-driver condition evaluation failed: {s}", .{@errorName(err)});
                    self.respondDriverFault(token, request.id, testdriver.Fault.internal_error);
                    return false;
                };
                if (matched) {
                    self.respondDriverResult(token, request.id, .ok);
                    return false;
                }
                if (wait.timeout_ms == 0) {
                    self.respondDriverFault(token, request.id, testdriver.Fault.timedOut("Condition timed out"));
                    return false;
                }
                const deadline = Io.Clock.real.now(self.io).nanoseconds +
                    @as(i128, wait.timeout_ms) * std.time.ns_per_ms;
                const retained = self.addDriverPending(.{
                    .token = token,
                    .parsed = parsed,
                    .state = .{ .wait = deadline },
                }) != null;
                if (!retained) self.respondDriverFault(
                    token,
                    request.id,
                    testdriver.Fault.unavailable("Driver queue full"),
                );
                return retained;
            },
            .get_logs => |logs| {
                const text = self.driverLogs(logs.max_bytes) catch |err| {
                    log.warn("test-driver log snapshot failed: {s}", .{@errorName(err)});
                    self.respondDriverFault(token, request.id, testdriver.Fault.internal_error);
                    return false;
                };
                defer self.allocator.free(text);
                self.respondDriverResult(token, request.id, .{ .logs = .{ .text = text } });
                return false;
            },
            .screenshot => {
                return self.retainDriverScreenshot(token, parsed, request.id);
            },
            .quit => {
                self.respondDriverResult(token, request.id, .ok);
                self.driver_quit_deadline_ns = Io.Clock.real.now(self.io).nanoseconds + 50 * std.time.ns_per_ms;
                return false;
            },
        }
    }

    fn drainDriverRequests(self: *App) void {
        const driver = self.driver orelse return;
        while (driver.takeRequest()) |request_value| {
            var raw = request_value;
            defer raw.deinit(self.allocator);
            var parsed = testdriver.parseRequest(self.allocator, raw.bytes) catch |err| {
                log.warn("test-driver request allocation failed: {s}", .{@errorName(err)});
                self.respondDriverFault(raw.token, null, testdriver.Fault.internal_error);
                continue;
            };
            const outcome = parsed.outcome;
            switch (outcome) {
                .failure => |failure| {
                    self.respondDriverFault(raw.token, failure.id, failure.fault);
                    parsed.deinit();
                },
                .request => {
                    const retained = self.executeDriverRequest(raw.token, parsed);
                    if (!retained) parsed.deinit();
                },
            }
        }
        if (driver.takeIssue()) |issue| {
            log.warn("test-driver transport issue: {s}", .{@tagName(issue)});
        }
    }

    fn pollDriverPending(self: *App) void {
        const now = Io.Clock.real.now(self.io).nanoseconds;
        var index: usize = 0;
        while (index < self.driver_pending.len) : (index += 1) {
            const pending = self.driver_pending[index] orelse continue;
            switch (pending.state) {
                .barrier => |barrier| {
                    if (barrier.posted) continue;
                    self.window.postDriverBarrier(barrier.id) catch continue;
                    self.driver_pending[index].?.state.barrier.posted = true;
                },
                .wait => |deadline| {
                    const request = switch (pending.parsed.outcome) {
                        .request => |request| request,
                        .failure => continue,
                    };
                    const wait = request.params.wait_for;
                    const matched = self.driverConditionMet(wait.condition) catch |err| {
                        log.warn("test-driver condition evaluation failed: {s}", .{@errorName(err)});
                        var failed = self.takeDriverPending(index);
                        self.respondDriverFault(failed.token, request.id, testdriver.Fault.internal_error);
                        failed.deinit(self.allocator);
                        continue;
                    };
                    if (!matched and now < deadline) continue;
                    var completed = self.takeDriverPending(index);
                    if (matched) {
                        self.respondDriverResult(completed.token, request.id, .ok);
                    } else {
                        self.respondDriverFault(completed.token, request.id, testdriver.Fault.timedOut("Condition timed out"));
                    }
                    completed.deinit(self.allocator);
                },
                .screenshot => |job| {
                    if (!job.finished()) continue;
                    if (job.thread) |thread| {
                        thread.join();
                        job.thread = null;
                    }
                    var completed = self.takeDriverPending(index);
                    const request = switch (completed.parsed.outcome) {
                        .request => |request| request,
                        .failure => {
                            completed.deinit(self.allocator);
                            continue;
                        },
                    };
                    if (job.failure) |name| {
                        log.warn("test-driver screenshot persistence failed: {s}", .{name});
                        self.respondDriverFault(completed.token, request.id, testdriver.Fault.internal_error);
                    } else {
                        self.respondDriverResult(completed.token, request.id, .{ .screenshot = .{ .path = job.path } });
                    }
                    completed.deinit(self.allocator);
                },
            }
        }
    }

    fn earliestDriverDeadline(self: *const App) ?i128 {
        var earliest = self.driver_quit_deadline_ns;
        for (self.driver_pending) |slot| {
            const pending = slot orelse continue;
            const deadline = switch (pending.state) {
                .wait => |deadline| deadline,
                .barrier, .screenshot => continue,
            };
            if (earliest == null or deadline < earliest.?) earliest = deadline;
        }
        return earliest;
    }

    /// Route committed platform text to the same focused destination a real
    /// input method sees. A semantic Input owns it when focused; otherwise the
    /// active terminal receives the exact UTF-8 bytes. Rejected external text
    /// leaves an Input unchanged and cannot terminate the event loop.
    fn commitTextInput(self: *App, text: []const u8) !void {
        if (self.closeModalActive()) return;
        if (self.activeUiTree().focusedInput()) |field| {
            field.insert(text) catch |err| {
                log.warn("committed input of {d} byte(s) rejected: {s}", .{ text.len, @errorName(err) });
                return;
            };
            if (field == &self.palette_query and self.palette_step == .commands) {
                self.palette_model.refresh(field.text());
            }
            if (field == &self.search_query and self.search_visible) self.restartSearch();
            try self.refreshActiveUi();
            return;
        }
        if (self.paletteVisible() or self.search_visible) return;
        self.presentedLive().terminal().userInput();
        queueCommittedText(&self.pending_committed_text, text);
        self.invalidateUi();
    }

    fn moveUiTest(self: *App, origin: ui.Rect) !void {
        const fixture = self.ui_test orelse return;
        fixture.origin = origin;
        try fixture.compose(self.uiGeometry());
        self.invalidateUi();
    }

    fn removeUiTest(self: *App) !void {
        const fixture = self.ui_test orelse return;
        try fixture.remove(self.uiGeometry());
        self.invalidateUi();
    }

    fn nativeTerminalLinkModifier(self: *const App, mods: platform.Mods) bool {
        return switch (self.binding_profile) {
            .macos => mods.super,
            .linux_windows => mods.ctrl,
        };
    }

    fn updateTerminalLinkModifier(self: *App, event: platform.Event) !void {
        if (self.ui_test != null) return;
        const mods = switch (event) {
            .key => |key| key.mods,
            .mouse_button => |button| button.mods,
            .mouse_motion => |motion| motion.mods,
            else => return,
        };
        const active = self.nativeTerminalLinkModifier(mods);
        if (active == self.terminal_link_modifier) return;
        self.terminal_link_modifier = active;
        try self.refreshActiveUi();
    }

    fn isTerminalLink(element: *const ui.Element) bool {
        return std.mem.eql(u8, element.role, "terminal_link");
    }

    fn terminalLinkPaneId(self: *const App, id: []const u8) ?workspace.PaneId {
        const target = self.terminalLinkTarget(id) orelse return null;
        const location = self.activeWorkspaceConst().paneForSession(target.session_id) orelse return null;
        const active_tab = self.activeWorkspaceConst().activeTabId() orelse return null;
        if (location.tab_id != active_tab) return null;
        return location.pane_id;
    }

    /// Give the active semantic tree first refusal of pointer gestures. Only
    /// an interactive top hit is owned; everything else remains terminal
    /// mouse input. Coordinates cross from SDL logical pixels to Tree device
    /// pixels exactly once at this boundary.
    fn pointInSidebar(self: *const App, point: ui.Point) bool {
        if (!self.sidebar_enabled or !self.sidebar_visible) return false;
        const sidebar_px = @as(u32, self.sidebarOriginColumns()) * self.fonts.metrics().cell.width_px;
        return point.x >= 0 and @as(u32, @intCast(point.x)) < sidebar_px;
    }

    fn clearUiFocus(self: *App, tree: *ui.Tree) !void {
        if (tree.focusedElement() == null) return;
        tree.clearFocus();
        try self.refreshActiveUi();
    }

    fn pointInCellRect(self: *const App, point: ui.Point, rect: ui.Rect) bool {
        if (point.x < 0 or point.y < 0) return false;
        const cell = self.fonts.metrics().cell;
        const x: u32 = @intCast(point.x);
        const y: u32 = @intCast(point.y);
        const left = rect.x * cell.width_px;
        const top = rect.y * cell.height_px;
        const right = rect.right() * cell.width_px;
        const bottom = rect.bottom() * cell.height_px;
        return x >= left and x < right and y >= top and y < bottom;
    }

    /// The command palette is a modal semantic surface. Pointer gestures
    /// inside it can only focus or activate its own elements; a press outside
    /// closes it and owns the matching release so nothing underneath fires.
    fn handlePaletteUiEvent(self: *App, event: platform.Event) !bool {
        const tree = self.activeUiTree();
        switch (event) {
            .mouse_motion => |motion| {
                const point = devicePointerPoint(motion.x, motion.y, self.window.state.scale);
                const before = uiInteractionState(tree);
                tree.pointerMoved(point);
                if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                return true;
            },
            .mouse_button => |button| {
                const point = devicePointerPoint(button.x, button.y, self.window.state.scale);
                if (button.button != .left) return true;
                switch (button.action) {
                    .press => {
                        const bounds = self.paletteBounds();
                        if (bounds == null or !self.pointInCellRect(point, bounds.?)) {
                            self.palette_pointer_owned = true;
                            try self.closePalette(true);
                            return true;
                        }
                        const before = uiInteractionState(tree);
                        tree.pointerPressed(point);
                        self.palette_pointer_owned = true;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        return true;
                    },
                    .repeat => return true,
                    .release => {
                        if (!self.palette_pointer_owned) return true;
                        const before = uiInteractionState(tree);
                        const activation = tree.pointerReleased(point);
                        self.palette_pointer_owned = false;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        if (activation) |requested| {
                            if (std.mem.eql(u8, requested.id.value, "palette.query") or
                                std.mem.eql(u8, requested.id.value, "palette.argument")) return true;
                            if (std.mem.eql(u8, requested.action, palette_activate_action)) {
                                try self.dispatchAction(palette_activate_action, .{
                                    .source = .mouse,
                                    .origin = requested.id,
                                });
                            }
                        }
                        return true;
                    },
                }
            },
            .wheel => return true,
            .text_input, .key => return false,
            .text_editing, .candidates => return switch (self.palette_step) {
                .commands, .input => false,
                .closed, .choices => true,
            },
            else => return false,
        }
    }

    /// Search keeps keyboard focus in its Input while letting mouse users
    /// activate the same named controls and highlighted matches. Every pointer
    /// gesture is owned until release so no tail reaches the terminal beneath
    /// the overlay.
    fn handleSearchUiEvent(self: *App, event: platform.Event) !bool {
        const tree = self.activeUiTree();
        switch (event) {
            .mouse_motion => |motion| {
                const point = devicePointerPoint(motion.x, motion.y, self.window.state.scale);
                const before = uiInteractionState(tree);
                tree.pointerMoved(point);
                if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                return true;
            },
            .mouse_button => |button| {
                if (button.button != .left) return true;
                const point = devicePointerPoint(button.x, button.y, self.window.state.scale);
                switch (button.action) {
                    .press => {
                        const hit = tree.hitTest(point) orelse return true;
                        const allowed = std.mem.startsWith(u8, hit.id.value, "search.");
                        if (!allowed or !hit.primitive.isInteractive()) return true;
                        const before = uiInteractionState(tree);
                        tree.pointerPressed(point);
                        self.search_pointer_owned = true;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        return true;
                    },
                    .repeat => return true,
                    .release => {
                        if (!self.search_pointer_owned) return true;
                        const before = uiInteractionState(tree);
                        const activation = tree.pointerReleased(point);
                        self.search_pointer_owned = false;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        if (activation) |requested| {
                            if (std.mem.eql(u8, requested.id.value, "search.query")) return true;
                            if (isSearchAction(requested.action)) try self.dispatchAction(requested.action, .{
                                .source = .mouse,
                                .origin = requested.id,
                            });
                        }
                        return true;
                    },
                }
            },
            .wheel => return true,
            .text_input, .text_editing, .candidates, .key => return false,
            else => return false,
        }
    }

    /// The scratchpad is modal for pointer ownership but its terminal body is
    /// still a real terminal input path. Chrome and every point outside the
    /// inner rectangle are consumed so no underlying pane/sidebar action can
    /// fire through the dock.
    fn handleScratchpadUiEvent(self: *App, event: platform.Event) !bool {
        const tree = self.activeUiTree();
        switch (event) {
            .mouse_motion => |motion| {
                const point = devicePointerPoint(motion.x, motion.y, self.window.state.scale);
                if (self.scratchpad_ui_pointer_owned) {
                    const before = uiInteractionState(tree);
                    tree.pointerMoved(point);
                    if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                    return true;
                }
                if (self.scratchpad_terminal_pointer_owned) return false;
                const before = uiInteractionState(tree);
                tree.pointerMoved(point);
                if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                const inner = self.scratchpadInnerRect() orelse return true;
                if (self.pointInCellRect(point, inner)) {
                    if (tree.hitTest(point)) |hit| {
                        if (isTerminalLink(hit)) return self.nativeTerminalLinkModifier(motion.mods);
                    }
                    return false;
                }
                return !self.pointInCellRect(point, inner);
            },
            .mouse_button => |button| {
                const point = devicePointerPoint(button.x, button.y, self.window.state.scale);
                const inner = self.scratchpadInnerRect();
                if (self.scratchpad_ui_pointer_owned) {
                    if (button.button != .left) return true;
                    switch (button.action) {
                        .press, .repeat => return true,
                        .release => {
                            const before = uiInteractionState(tree);
                            const activation = tree.pointerReleased(point);
                            self.scratchpad_ui_pointer_owned = false;
                            if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                            if (activation) |requested| {
                                const allowed = std.mem.eql(u8, requested.action, scratchpad_restart_action) or
                                    std.mem.eql(u8, requested.action, scratchpad_hide_action) or
                                    std.mem.eql(u8, requested.action, terminal_open_link_action);
                                if (allowed) try self.dispatchAction(requested.action, .{
                                    .source = .mouse,
                                    .origin = requested.id,
                                });
                            }
                            return true;
                        },
                    }
                }
                if (self.scratchpad_terminal_pointer_owned) {
                    if (button.action == .release) self.scratchpad_terminal_pointer_owned = false;
                    return false;
                }
                if (inner != null and self.pointInCellRect(point, inner.?)) {
                    const hit = tree.hitTest(point);
                    if (button.button == .left and button.action == .press and
                        self.nativeTerminalLinkModifier(button.mods) and hit != null and isTerminalLink(hit.?))
                    {
                        const before = uiInteractionState(tree);
                        tree.pointerPressed(point);
                        self.scratchpad_ui_pointer_owned = true;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        return true;
                    }
                    if (button.action == .press) {
                        self.scratchpad_terminal_pointer_owned = true;
                        try self.clearUiFocus(tree);
                    }
                    return false;
                }
                if (button.button != .left) return true;
                switch (button.action) {
                    .press => {
                        const hit = tree.hitTest(point) orelse return true;
                        const scratch_action = std.mem.eql(u8, hit.action orelse "", scratchpad_restart_action) or
                            std.mem.eql(u8, hit.action orelse "", scratchpad_hide_action);
                        if (!scratch_action or !hit.primitive.isInteractive()) return true;
                        const before = uiInteractionState(tree);
                        tree.pointerPressed(point);
                        self.scratchpad_ui_pointer_owned = true;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        return true;
                    },
                    .repeat => return true,
                    .release => {
                        return true;
                    },
                }
            },
            .wheel => |wheel| {
                const point = devicePointerPoint(wheel.x, wheel.y, self.window.state.scale);
                const inner = self.scratchpadInnerRect() orelse return true;
                return !self.pointInCellRect(point, inner);
            },
            else => return false,
        }
    }

    fn handleUiEvent(self: *App, event: platform.Event) !bool {
        try self.updateTerminalLinkModifier(event);
        const tree = self.activeUiTree();
        if (self.activeWorkspaceClosing()) switch (event) {
            .key, .text_input, .text_editing, .candidates, .mouse_button, .mouse_motion, .wheel => return true,
            else => {},
        };
        if (!self.paletteVisible() and self.palette_pointer_owned) switch (event) {
            .mouse_motion => return true,
            .mouse_button => |button| {
                if (button.action == .release) self.palette_pointer_owned = false;
                return true;
            },
            else => {},
        };
        if (!self.contextMenuVisible() and self.context_menu_pointer_owned) switch (event) {
            .mouse_motion => return true,
            .mouse_button => |button| {
                if (button.action == .release) self.context_menu_pointer_owned = false;
                return true;
            },
            else => {},
        };
        if (self.contextMenuVisible()) return self.handleContextMenuUiEvent(event);
        if (self.paletteVisible()) return self.handlePaletteUiEvent(event);
        if (self.search_visible) return self.handleSearchUiEvent(event);
        if (self.closeModalActive()) switch (event) {
            .text_input, .text_editing, .candidates => return true,
            else => {},
        };
        // A presentation chord may hide the scratchpad while a pointer press
        // is still owned by its terminal or chrome. Retain that ownership
        // through release so the tail of the gesture cannot land in the pane
        // that was just revealed.
        if (!self.scratchpadVisible() and
            (self.scratchpad_ui_pointer_owned or self.scratchpad_terminal_pointer_owned))
        {
            switch (event) {
                .mouse_motion => return true,
                .mouse_button => |button| {
                    if (button.action == .release) {
                        self.scratchpad_ui_pointer_owned = false;
                        self.scratchpad_terminal_pointer_owned = false;
                    }
                    return true;
                },
                else => {},
            }
        }
        if (self.scratchpadVisible() and !self.closeModalActive()) return self.handleScratchpadUiEvent(event);
        switch (event) {
            .mouse_motion => |motion| {
                const point = devicePointerPoint(motion.x, motion.y, self.window.state.scale);
                if (self.sidebar_dragging) {
                    const cell_width = self.fonts.metrics().cell.width_px;
                    const nonnegative_x: u32 = if (point.x <= 0) 0 else @intCast(point.x);
                    const desired: u16 = @intCast(@min(
                        nonnegative_x / cell_width + 1,
                        @as(u32, sidebar_max_width),
                    ));
                    self.sidebar_width_cols = @max(desired, sidebar_min_width);
                    try self.syncGrid();
                    try self.composeUi();
                    self.invalidateUi();
                    return true;
                }
                if (self.dragged_divider_id) |divider_id| {
                    const split = self.dragged_divider_split orelse return true;
                    const cell = self.fonts.metrics().cell;
                    const axis_px: i32 = if (split == .right) point.x else point.y;
                    const cell_px: i32 = @intCast(if (split == .right) cell.width_px else cell.height_px);
                    const current_cell = @divFloor(axis_px, @max(cell_px, 1));
                    const delta = current_cell - self.divider_drag_cell;
                    if (delta != 0) {
                        var divider_buffer: [16]u8 = undefined;
                        var delta_buffer: [16]u8 = undefined;
                        const divider_text = try std.fmt.bufPrint(&divider_buffer, "{d}", .{@intFromEnum(divider_id)});
                        const delta_text = try std.fmt.bufPrint(&delta_buffer, "{d}", .{delta});
                        const args = [_]inputmod.Argument{
                            .{ .name = "divider", .value = divider_text },
                            .{ .name = "delta", .value = delta_text },
                        };
                        try self.dispatchAction(pane_resize_action, .{ .source = .mouse, .arguments = &args });
                        self.divider_drag_cell = current_cell;
                    }
                    return true;
                }
                if (self.ui_pointer_owned) {
                    const before = uiInteractionState(tree);
                    tree.pointerMoved(point);
                    if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                    // Ownership lasts from press through release. In
                    // particular, a deferred pane activation must not turn a
                    // held drag into motion for the previously active pane.
                    return paneMotionOwnedByUi(true, null, null, motion.buttons);
                }
                if (tree.hitTest(point)) |hit| {
                    const link_hit = isTerminalLink(hit);
                    if (std.mem.eql(u8, hit.role, "pane") or link_hit) {
                        const pane_id = if (link_hit)
                            self.terminalLinkPaneId(hit.id.value)
                        else
                            self.paneIdForSemantic(hit.id.value);
                        const before = uiInteractionState(tree);
                        tree.pointerMoved(point);
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        if (link_hit and self.terminal_pointer_presses == 0 and
                            self.nativeTerminalLinkModifier(motion.mods)) return true;
                        const tab_id = self.activeWorkspace().activeTabId();
                        const focused = if (tab_id) |id| self.activeWorkspace().focusedPaneId(id) else null;
                        return paneMotionOwnedByUi(false, pane_id, focused, motion.buttons);
                    }
                }
                const before = uiInteractionState(tree);
                tree.pointerMoved(point);
                const after = uiInteractionState(tree);
                if (!std.meta.eql(before, after)) try self.refreshActiveUi();
                if (self.closeModalActive()) return true;
                return self.ui_pointer_owned or before.hovered != null or after.hovered != null or
                    self.pointInSidebar(point);
            },
            .mouse_button => |button| {
                const point = devicePointerPoint(button.x, button.y, self.window.state.scale);
                if (button.button != .left) {
                    if (self.closeModalActive()) return true;
                    if (tree.hitTest(point)) |hit| {
                        if (std.mem.eql(u8, hit.role, "pane") or isTerminalLink(hit)) {
                            const tab_id = self.activeWorkspace().activeTabId() orelse return true;
                            const pane_id = if (isTerminalLink(hit))
                                self.terminalLinkPaneId(hit.id.value)
                            else
                                self.paneIdForSemantic(hit.id.value);
                            if (pane_id != self.activeWorkspace().focusedPaneId(tab_id)) return true;
                            if (button.button == .right and button.action == .press and
                                try self.handleTerminalRightPress(point, hit, button.mods)) return true;
                        }
                    }
                    if (button.action == .press and !self.pointInSidebar(point)) {
                        try self.clearUiFocus(tree);
                    }
                    return self.pointInSidebar(point);
                }
                switch (button.action) {
                    .press => {
                        const hit = tree.hitTest(point) orelse {
                            if (self.closeModalActive()) {
                                self.ui_pointer_owned = true;
                                return true;
                            }
                            try self.clearUiFocus(tree);
                            return self.pointInSidebar(point);
                        };
                        if (self.closeModalActive()) {
                            const cancel_id = if (self.pending_close_workspace != null) "workspace-close.cancel" else "tab-close.cancel";
                            const confirm_id = if (self.pending_close_workspace != null) "workspace-close.confirm" else "tab-close.confirm";
                            if (!std.mem.eql(u8, hit.id.value, cancel_id) and
                                !std.mem.eql(u8, hit.id.value, confirm_id))
                            {
                                self.ui_pointer_owned = true;
                                return true;
                            }
                        }
                        if (isTerminalLink(hit)) {
                            if (self.nativeTerminalLinkModifier(button.mods)) {
                                const before = uiInteractionState(tree);
                                tree.pointerPressed(point);
                                self.ui_pointer_owned = true;
                                if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                                return true;
                            }
                            const pane_id = self.terminalLinkPaneId(hit.id.value) orelse return false;
                            var pane_id_buffer: [pane_semantic_capacity]u8 = undefined;
                            const pane_semantic = try paneSemanticId(
                                &pane_id_buffer,
                                self.activePresentation().key,
                                pane_id,
                            );
                            try self.dispatchAction(pane_activate_action, .{
                                .source = .mouse,
                                .origin = .{ .value = pane_semantic },
                            });
                            const tab_id = self.activeWorkspace().activeTabId();
                            const focused_after = if (tab_id) |id| self.activeWorkspace().focusedPaneId(id) else null;
                            if (!panePressRoutesToTerminal(pane_id, focused_after)) {
                                self.ui_pointer_owned = true;
                                return true;
                            }
                            try self.clearUiFocus(tree);
                            return false;
                        }
                        if (!hit.primitive.isInteractive()) {
                            if (self.closeModalActive()) {
                                self.ui_pointer_owned = true;
                                return true;
                            }
                            try self.clearUiFocus(tree);
                            if (!self.pointInSidebar(point)) return false;
                            self.ui_pointer_owned = true;
                            return true;
                        }
                        if (std.mem.eql(u8, hit.role, "pane")) {
                            const pane_id = self.paneIdForSemantic(hit.id.value) orelse return false;
                            var pane_id_buffer: [pane_semantic_capacity]u8 = undefined;
                            const pane_semantic = try paneSemanticId(
                                &pane_id_buffer,
                                self.activePresentation().key,
                                pane_id,
                            );
                            try self.dispatchAction(pane_activate_action, .{
                                .source = .mouse,
                                .origin = .{ .value = pane_semantic },
                            });
                            const tab_id = self.activeWorkspace().activeTabId();
                            const focused_after = if (tab_id) |id| self.activeWorkspace().focusedPaneId(id) else null;
                            if (!panePressRoutesToTerminal(pane_id, focused_after)) {
                                // The focus action can defer while the old pane
                                // still has unwritten bytes. Own the full gesture
                                // so neither press nor release reaches that pane.
                                self.ui_pointer_owned = true;
                                return true;
                            }
                            try self.clearUiFocus(tree);
                            // Focusing does not consume the press: the same
                            // gesture begins selection or mouse reporting in
                            // the pane the user actually clicked.
                            return false;
                        }
                        self.sidebar_dragging = std.mem.eql(u8, hit.id.value, "sidebar.divider");
                        self.dragged_divider_id = self.dividerIdForSemantic(hit.id.value);
                        if (self.dragged_divider_id != null) {
                            for (self.divider_layouts[0..self.divider_layout_count]) |divider| {
                                if (divider.divider_id != self.dragged_divider_id.?) continue;
                                self.dragged_divider_split = divider.split;
                                const cell = self.fonts.metrics().cell;
                                const axis_px: i32 = if (divider.split == .right) point.x else point.y;
                                const cell_px: i32 = @intCast(if (divider.split == .right) cell.width_px else cell.height_px);
                                self.divider_drag_cell = @divFloor(axis_px, @max(cell_px, 1));
                                break;
                            }
                        }
                        self.dragged_tab_id = if (std.mem.eql(u8, hit.role, "tab"))
                            self.tabIdForSemantic(hit.id.value)
                        else
                            null;
                        const before = uiInteractionState(tree);
                        tree.pointerPressed(point);
                        self.ui_pointer_owned = true;
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        return true;
                    },
                    .repeat => return self.closeModalActive() or self.ui_pointer_owned or self.pointInSidebar(point),
                    .release => {
                        if (!self.ui_pointer_owned) return self.closeModalActive() or self.pointInSidebar(point);
                        const drop_id: ?[]const u8 = if (tree.hitTest(point)) |target|
                            if (std.mem.eql(u8, target.role, "tab")) target.id.value else null
                        else
                            null;
                        const dragged = self.dragged_tab_id;
                        const dragged_divider = self.dragged_divider_id;
                        const before = uiInteractionState(tree);
                        const activation = tree.pointerReleased(point);
                        self.ui_pointer_owned = false;
                        self.sidebar_dragging = false;
                        self.dragged_divider_id = null;
                        self.dragged_divider_split = null;
                        self.dragged_tab_id = null;
                        // A pointer drag resizes the divider but must not leave
                        // keyboard focus on it: the next ordinary key still
                        // belongs to the focused terminal.
                        if (dragged_divider != null) tree.clearFocus();
                        if (!std.meta.eql(before, uiInteractionState(tree))) try self.refreshActiveUi();
                        if (dragged) |source_id| if (drop_id) |target_semantic| {
                            const target_id = self.tabIdForSemantic(target_semantic);
                            if (target_id != null and target_id.? != source_id) {
                                _ = self.activeWorkspace().tab(source_id) orelse return true;
                                var source_storage: [workspace_semantic_capacity]u8 = undefined;
                                const source_semantic = try tabSemanticId(
                                    &source_storage,
                                    self.activePresentation().key,
                                    source_id,
                                );
                                const args = [_]inputmod.Argument{.{ .name = "target", .value = target_semantic }};
                                try self.dispatchAction(tab_reorder_action, .{
                                    .source = .mouse,
                                    .origin = .{ .value = source_semantic },
                                    .arguments = &args,
                                });
                                return true;
                            }
                        };
                        if (dragged_divider == null) {
                            if (activation) |requested| try self.dispatchAction(requested.action, .{
                                .source = .mouse,
                                .origin = requested.id,
                            });
                        }
                        return true;
                    },
                }
            },
            .wheel => |wheel| {
                const point = devicePointerPoint(wheel.x, wheel.y, self.window.state.scale);
                if (self.closeModalActive() or self.pointInSidebar(point)) return true;
                if (tree.hitTest(point)) |hit| {
                    if (std.mem.eql(u8, hit.role, "pane") or isTerminalLink(hit)) {
                        const tab_id = self.activeWorkspace().activeTabId() orelse return true;
                        const pane_id = if (isTerminalLink(hit))
                            self.terminalLinkPaneId(hit.id.value)
                        else
                            self.paneIdForSemantic(hit.id.value);
                        return pane_id != self.activeWorkspace().focusedPaneId(tab_id);
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    /// Draw one frame and put it on screen if anyone can see it.
    ///
    /// P6 as call order — the grid renderer and the UI renderer draw into this
    /// one surface in sequence.
    fn drawFrame(self: *App) !void {
        try self.pumpChild();
        try self.syncGrid();
        for (self.pane_layouts[0..self.pane_layout_count]) |layout| {
            const live = self.activeWorkspace().sessionById(layout.session_id) orelse continue;
            try live.terminal().refresh(self.allocator);
        }
        if (self.scratchpadVisible()) {
            if (self.scratchpadLive()) |scratchpad| try scratchpad.terminal().refresh(self.allocator);
        }
        try self.syncTextInput();
        if (self.ui_test == null) try self.composeUi();
        const overlay = self.overlayView();
        const repaint_base = try self.overlay_grid.prepareCanvasOverlay(&self.fonts, overlay);
        var base_changed = repaint_base or self.needs_present;
        if (base_changed) {
            self.surface.clear(self.background);
            for (self.activePresentation().pane_renderers.items) |*record| record.grid.invalidate();
            self.activePresentation().scratchpad_grid.invalidate();
        }
        const cell = self.fonts.metrics().cell;
        for (self.pane_layouts[0..self.pane_layout_count]) |layout| {
            const live = self.activeWorkspace().sessionById(layout.session_id) orelse continue;
            const grid = self.rendererForSession(layout.session_id) orelse continue;
            const before = grid.gridStats();
            var viewport = render.GridViewport.fromCells(
                .{ .col = layout.rect.col, .row = layout.rect.row },
                live.terminal().gridSize(),
                cell,
            );
            viewport.dimmed = !layout.focused;
            try grid.drawViewport(&self.surface, &self.fonts, live.terminal(), self.blink_visible, viewport);
            const after = grid.gridStats();
            base_changed = base_changed or after.frames != before.frames or after.draws != before.draws;
        }
        if (self.scratchpadInnerRect()) |inner| {
            if (self.scratchpadLive()) |scratchpad| {
                const before = self.activePresentation().scratchpad_grid.gridStats();
                const viewport = render.GridViewport.fromCells(
                    .{ .col = inner.x, .row = inner.y },
                    scratchpad.terminal().gridSize(),
                    cell,
                );
                try self.activePresentation().scratchpad_grid.drawViewport(
                    &self.surface,
                    &self.fonts,
                    scratchpad.terminal(),
                    self.blink_visible,
                    viewport,
                );
                const after = self.activePresentation().scratchpad_grid.gridStats();
                base_changed = base_changed or after.frames != before.frames or after.draws != before.draws;
            }
        }
        const overlay_before = self.overlay_grid.gridStats();
        try self.overlay_grid.drawCanvasOverlay(&self.surface, &self.fonts, overlay, base_changed);
        const overlay_after = self.overlay_grid.gridStats();
        if (base_changed or overlay_after.overlay_frames != overlay_before.overlay_frames or self.needs_present) {
            try self.surface.present(self.window);
            self.needs_present = false;
        }
        self.scheduler.drawn();
        log.debug("frame {d}: {d}x{d} at scale {d:.2}", .{
            self.scheduler.frames,
            self.size.width,
            self.size.height,
            self.window.state.scale.factor,
        });
    }

    /// Read the surface back into the app's buffer: the pixels as they stand
    /// now.
    ///
    /// The returned slice is the app's reused buffer and must not be freed by
    /// the caller. This is the same path a screenshot takes, which is what
    /// makes a headless capture the same image a user would see.
    fn capture(self: *App) ![]const u8 {
        return self.surface.read(self.readback);
    }

    /// React to one event. Returns whether the loop should keep running.
    fn handle(self: *App, event: platform.Event) !bool {
        switch (event) {
            .driver_wake => {
                self.drainDriverRequests();
                self.pollDriverPending();
                return true;
            },
            .driver_barrier => |barrier_id| {
                self.finishDriverBarrier(barrier_id);
                self.pollDriverPending();
                return true;
            },
            else => {},
        }
        if (try self.handleUiEvent(event)) {
            if (!self.requested_shutdown) self.pollDriverPending();
            return !self.requested_shutdown;
        }
        switch (routeInputMethodEvent(&self.composition, event)) {
            .preedit => self.invalidateUi(),
            .candidates => {},
            .committed => |text| try self.commitTextInput(text),
            .unrelated => switch (event) {
                .resized => |state| {
                    log.info("event resized: {d}x{d} logical, surface {d}x{d}", .{
                        state.logical.width,
                        state.logical.height,
                        state.surface.width_px,
                        state.surface.height_px,
                    });
                    try self.syncSurface(state);
                },
                .scale_changed => |change| {
                    log.info("event display scale changed: {d:.2} -> {d:.2}, surface {d}x{d}", .{
                        change.previous.factor,
                        change.state.scale.factor,
                        change.state.surface.width_px,
                        change.state.surface.height_px,
                    });
                    try self.syncSurface(change.state);
                },
                .focused => log.debug("event focus gained", .{}),
                .unfocused => log.debug("event focus lost", .{}),
                .exposed => {
                    log.debug("event exposed: the surface on screen may be stale", .{});
                    self.scheduler.invalidate();
                    self.needs_present = true;
                },
                .close_requested => {
                    log.info("event close requested: leaving", .{});
                    return false;
                },
                .quit => {
                    log.info("event quit: leaving", .{});
                    return false;
                },
                // A wheel is the terminal's own decision: whether it scrolls
                // the viewport or goes to the running program depends on which
                // screen is up and what modes the program has set.
                .wheel => |wheel| try self.onWheel(wheel),
                // A pointer event is the terminal's decision for the same
                // reason: a program can capture it, and Shift gives it back.
                .mouse_button => |button| try self.onPointerButton(button),
                .mouse_motion => |motion| try self.onPointerMotion(motion),
                // Every key goes through `onKey`: a clipboard chord is the
                // clipboard's, and every other key reaches the program.
                .key => |key| try self.onKey(key),
                .clipboard_updated => |update| log.debug("event clipboard changed, owned={}", .{update.owned}),
                .driver_wake, .driver_barrier => unreachable,
                // The helper returned `.unrelated`, so reaching one of its
                // three tags would be an internal routing contradiction.
                .text_input, .text_editing, .candidates => unreachable,
            },
        }
        // Input goes out as soon as it is made, through the one write site,
        // rather than waiting for a frame: a Ctrl+C must not sit behind a
        // redraw nobody asked for, and the next pointer event reuses the
        // staging buffer.
        if (self.requested_shutdown or self.workspace_registry.count() == 0) return false;
        try self.flushToChild();
        self.pollDriverPending();
        return !self.requested_shutdown;
    }

    /// How long this iteration may block waiting for a window event.
    ///
    /// With no child and no blinking cursor there is nothing outside the queue
    /// that can change the screen, so the wait is the run's own deadline and
    /// nothing more. With either there is, and the wait is cut to one tick: the
    /// loop cannot wait on the PTY's wakeup and SDL's queue at once, so it asks
    /// the terminal whether anything has arrived and gives up after this long.
    fn waitBudget(self: *App, io: Io, deadline_ns: ?i128) i32 {
        const driver_deadline = self.earliestDriverDeadline();
        const effective_deadline = if (deadline_ns) |run_deadline|
            if (driver_deadline) |pending_deadline| @min(run_deadline, pending_deadline) else run_deadline
        else
            driver_deadline;
        const budget = eventWaitBudget(io, effective_deadline, self.scheduler.force);
        var has_load = self.font_load != null;
        var has_attached_child = false;
        for (self.workspace_presentations.items) |presentation| {
            has_load = has_load or presentation.load != null or presentation.scratchpad_load != null;
            if (self.workspace_registry.byKey(presentation.key)) |model| {
                has_attached_child = has_attached_child or model.hasAttachedChild();
            }
        }
        if (has_load) {
            if (budget < 0) return idle_tick_ms;
            return @min(budget, idle_tick_ms);
        }
        if (!has_attached_child and !self.cursorBlinks() and !self.searchNeedsWork()) return budget;
        if (budget < 0) return idle_tick_ms;
        return @min(budget, idle_tick_ms);
    }

    /// The event loop.
    ///
    /// One iteration is one wait for an event, one look at everything outside
    /// the event queue, and then at most one frame. The wait is a blocking wait
    /// inside SDL, so a window nobody is touching costs no CPU: no polling
    /// timer, no sleep-and-retry, and no frame that nothing asked for.
    /// `deadline_ns`, when given, is the only reason to wake up on a timer.
    ///
    /// A frame owed when the deadline arrives is drawn before the loop leaves.
    /// The resize that resized the surface is what invalidated it, and a run
    /// that ended with the surface resized and not yet drawn into would leave
    /// the user looking at a texture the app never touched.
    ///
    /// In force mode the wait is a non-blocking poll rather than a blocking
    /// wait, because a loop that drew every frame is exactly a loop that does
    /// not sleep: leaving the blocking wait in place would make
    /// `--force-redraw` measure the same idle cost as render-on-demand and
    /// prove nothing.
    fn run(self: *App, io: Io, deadline_ns: ?i128) !void {
        while (true) {
            const event = self.window.pump(self.waitBudget(io, deadline_ns));
            if (event) |one| {
                if (!try self.handle(one)) break;
            }
            if (self.poll()) self.scheduler.invalidate();
            if (self.requested_shutdown) break;
            if (self.scheduler.shouldDraw()) try self.drawFrame();
            self.pollDriverPending();
            if (self.driver_quit_deadline_ns) |quit_deadline| {
                if (Io.Clock.real.now(io).nanoseconds >= quit_deadline) break;
            }
            if (self.childGone()) break;
            // The wait expired with nothing to report, which is the normal state
            // of an idle window, and the only thing that ends a bounded run.
            if (event == null) {
                if (deadline_ns) |deadline| {
                    if (Io.Clock.real.now(io).nanoseconds >= deadline) break;
                }
            }
        }
    }
};

/// The longest wait the loop ever asks for, in milliseconds. SDL takes a signed
/// 32-bit count, and a negative one means "block until an event arrives".
const max_wait_ms: i32 = std.math.maxInt(i32);

/// With no deadline the loop blocks indefinitely, which is what makes an idle
/// window free: SDL sleeps until something happens. With one, the wait is cut to
/// exactly what is left, so the run leaves when it said it would rather than one
/// poll later. `poll` asks for a zero-length wait instead, which is what force
/// mode needs.
fn eventWaitBudget(io: Io, deadline_ns: ?i128, poll: bool) i32 {
    if (poll) return 0;
    const deadline = deadline_ns orelse return -1;
    const left = deadline - Io.Clock.real.now(io).nanoseconds;
    if (left <= 0) return 0;
    const ms = @divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms);
    return @intCast(std.math.clamp(ms, 0, @as(i128, max_wait_ms)));
}

/// The instant a run leaves, from `--run-ms`. `null` means it leaves when the
/// window closes.
fn runDeadline(io: Io, run_ms: ?u32) ?i128 {
    const ms = run_ms orelse return null;
    return Io.Clock.real.now(io).nanoseconds + @as(i128, ms) * std.time.ns_per_ms;
}

// ---------------------------------------------------------------------------
// The self-test
// ---------------------------------------------------------------------------

/// How long `--self-test` waits for each event it provokes, in milliseconds.
const self_test_event_budget_ms: i64 = 2000;

/// How long `--self-test` leaves the loop alone to see whether it draws, in
/// milliseconds.
const self_test_idle_ms: i64 = 1000;

/// How long the self-test waits for the event queue to go quiet before measuring
/// anything, in milliseconds. Long enough that a slow compositor's second resize
/// has arrived, short enough that draining a queue is not a pause.
const settle_quiet_ms: i32 = 250;

/// What the self-test is waiting for.
///
/// A resize is waited for by *size*, not by event kind: SDL sends a resize
/// event when a window is first configured, before the app has asked for
/// anything, so "the next resize event arrived" would be satisfied by an event
/// that has nothing to do with the request. Waiting for the size that was asked
/// for is what makes the step prove the request reached the window.
const Awaited = union(enum) {
    /// A resize that leaves the window at this logical size.
    resize: platform.LogicalSize,
    /// Any display-scale change.
    scale,
    /// Any wheel event.
    wheel,
    /// A close request.
    close,
    /// Any pointer button going down or coming up.
    pointer_button,
    /// Any pointer motion.
    pointer_motion,
    /// Any key going down or coming up.
    key,
    /// Any input-method preedit update.
    text_editing,
    /// Any input-method commit.
    text_input,
};

/// Whether `event` is the one `awaited` is waiting for.
fn isAwaited(awaited: Awaited, event: platform.Event) bool {
    return switch (awaited) {
        .resize => |size| switch (event) {
            .resized => |state| std.meta.eql(state.logical, size),
            else => false,
        },
        .scale => event == .scale_changed,
        .wheel => event == .wheel,
        .close => event == .close_requested,
        // Matched by tag rather than by `==`: the payloads carry the position
        // and the modifiers, and two pointer events are not equal just because
        // they are both pointer events.
        .pointer_button => switch (event) {
            .mouse_button => true,
            else => false,
        },
        .pointer_motion => switch (event) {
            .mouse_motion => true,
            else => false,
        },
        .key => switch (event) {
            .key => true,
            else => false,
        },
        .text_editing => switch (event) {
            .text_editing => true,
            else => false,
        },
        .text_input => switch (event) {
            .text_input => true,
            else => false,
        },
    };
}

/// How many numbered lines `--scroll-test` prints before it scrolls.
const scroll_test_lines: usize = 400;

/// How far `--scroll-test` scrolls back, in wheel notches. Positive is away
/// from the user, which is what moves the viewport into history.
const scroll_test_notches: f32 = 6;

/// Check that scrolling back through history changes what the window shows.
///
/// The lines go in through the real parser and the wheel comes through a real
/// SDL event, so the path under test is the one a person's wheel takes: SDL's
/// queue, `App.handle`, `onWheel`, the terminal, and then the pixels.
///
/// The child is deliberately absent: the numbered lines are fed straight in, so
/// this measures scrolling rather than how fast a shell can print. The
/// real-child version — a shell printing `seq`, and `less` receiving the wheel
/// as arrow keys — lives in `term`'s integration tests.
fn scrollTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;

    var line: [64]u8 = undefined;
    for (1..scroll_test_lines + 1) |n| {
        self.activeLive().terminal().feed(try std.fmt.bufPrint(&line, "\r\nconduit-scroll-{d}\r\n", .{n}));
    }
    if (self.scheduler.shouldDraw()) try self.drawFrame();

    const at_bottom = self.activeLive().terminal().viewport();
    out.print(
        "scroll-test: {d} lines fed, history rows {d}, view rows {d}, offset {d}\n",
        .{ scroll_test_lines, at_bottom.history_rows, at_bottom.view_rows, at_bottom.offset },
    ) catch {};
    try self.drawFrame();
    // The capture is the app's reused readback buffer, so the first one is
    // copied out before anything else reads it: comparing it with a later
    // capture would be comparing one buffer with itself.
    const bottom_pixels = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(bottom_pixels);

    // A wheel away from the user, through SDL, so the whole path runs.
    const cell = self.fonts.metrics().cell;
    try self.window.postWheel(.{
        .dy = scroll_test_notches,
        .x = @as(f32, @floatFromInt(cell.width_px)) / 2,
        .y = @as(f32, @floatFromInt(cell.height_px)) / 2,
    });
    // Wait for the wheel to come back through SDL's queue rather than assuming
    // it has already been delivered: an event the app posted is delivered when
    // the queue is pumped, and a measurement taken before that measures a wheel
    // that has not happened yet.
    if (!try pumpUntil(self, io, out, .wheel, self_test_event_budget_ms)) {
        out.print("scroll-test: FAIL no wheel event arrived\n", .{}) catch {};
        failures += 1;
    }
    if (self.scheduler.shouldDraw()) try self.drawFrame();

    const scrolled = self.activeLive().terminal().viewport();

    // A trackpad reports fractional travel rather than notches. What matters
    // here is that small gestures do not run the view away: many sub-row
    // gestures must add up to at most the row they carry.
    //
    // Note the unit problem this exposes, recorded on TASK-13: SDL reports wheel
    // travel with no unit, so `platform` calls a delta precise when it is
    // fractional and `term` divides a precise delta by `pixels_per_row`. A
    // trackpad that reports halves therefore moves a twentieth of a row per
    // gesture. That is defensible — nothing jumps — but it is slow, and the
    // ratio wants a decision before v0.1.
    const after_wheel = scrolled.offset;
    const pointer = .{
        .x = @as(f32, @floatFromInt(cell.width_px)) / 2,
        .y = @as(f32, @floatFromInt(cell.height_px)) / 2,
    };
    var offset_after_each: [4]usize = undefined;
    for (0..4) |i| {
        try self.window.postWheel(.{
            .dy = 0.5,
            .precise = true,
            .x = pointer.x,
            .y = pointer.y,
        });
        if (!try pumpUntil(self, io, out, .wheel, self_test_event_budget_ms)) {
            out.print("scroll-test: FAIL trackpad gesture {d} did not arrive\n", .{i + 1}) catch {};
            failures += 1;
        }
        offset_after_each[i] = self.activeLive().terminal().viewport().offset;
    }
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    out.print("scroll-test: four trackpad half-deltas moved {d}, {d}, {d}, {d} rows (offset {d} -> {d})\n", .{
        offset_after_each[0] - after_wheel,
        offset_after_each[1] - after_wheel,
        offset_after_each[2] - after_wheel,
        offset_after_each[3] - after_wheel,
        after_wheel,
        offset_after_each[3],
    }) catch {};
    if (offset_after_each[3] > after_wheel + 1) {
        out.print("scroll-test: FAIL sub-row travel ran the view away\n", .{}) catch {};
        failures += 1;
    }
    out.print(
        "scroll-test: after {d} notches away, offset {d} of {d} history rows\n",
        .{ @as(u32, @intFromFloat(scroll_test_notches)), scrolled.offset, scrolled.history_rows },
    ) catch {};

    if (scrolled.offset == 0) {
        out.print("scroll-test: FAIL the viewport did not move back into history\n", .{}) catch {};
        failures += 1;
    }

    const scrolled_pixels = try self.capture();
    const differing = countDifferingPixels(bottom_pixels, scrolled_pixels);
    if (differing == 0) {
        out.print("scroll-test: FAIL the surface is unchanged after scrolling back\n", .{}) catch {};
        failures += 1;
    } else {
        out.print("scroll-test: {d} pixels differ between the bottom and the scrolled view\n", .{
            differing,
        }) catch {};
    }

    // The top row as the terminal holds it: the claim is that the view shows
    // history, not that it shows blanks.
    out.writeAll("scroll-test: top row: ") catch {};
    try writeGridRow(out, self, 0);
    out.writeAll("\n") catch {};
    out.flush() catch {};

    try self.window.postCloseRequest();
    if (!try pumpUntil(self, io, out, .close, self_test_event_budget_ms)) {
        out.flush() catch {};
        return error.SelfTestCloseNotDelivered;
    }

    out.print("scroll-test: {d} failure(s)\n", .{failures}) catch {};
    return if (failures == 0) 0 else 1;
}

// ---------------------------------------------------------------------------
// The mouse check
// ---------------------------------------------------------------------------

/// How many rows `--mouse-test` prints before the pointer arrives. More than a
/// screenful, so the check has scrollback to scroll back through and the drag
/// has rows to cross.
const mouse_test_lines: usize = 60;

/// The row of known text `--mouse-test` first selects in, and the columns its
/// drag runs between. Named so every measurement below says which cells it is
/// about rather than repeating three bare numbers in eight places. The later
/// click checks find `bravo` in the live grid because scrolling and output have
/// deliberately moved the original row by then.
const mouse_test_row: u16 = 8;
const mouse_test_drag_from: u16 = 4;
const mouse_test_drag_to: u16 = 12;

/// What `vim` sends when `set mouse=a` has taken effect, verbatim: captured off
/// the program over a pty, and pinned byte for byte against a real `vim` in
/// `term`'s own integration tests. Feeding it is how a run with no child turns
/// the mouse on the way a program does, rather than by setting modes by hand.
const mouse_test_capture = "\x1b[?1006;1000h\x1b[?1002h";

/// What a program sends when it gives the mouse back: the three DECRSTs that
/// clear 1002, 1000 and 9.
const mouse_test_release = "\x1b[?1002l\x1b[?1000l\x1b[?9l";

/// The middle of the cell at `col`, `row`, in device pixels.
///
/// The middle rather than a corner, for the reason `atCell` gives in `term`: a
/// corner is the one position where a rounding decision could change which
/// cell is meant.
fn cellPosition(self: *const App, col: u16, row: u16) struct { x: f32, y: f32 } {
    const cell = self.fonts.metrics().cell;
    const scale = self.window.state.scale.factor;
    const width: f32 = @as(f32, @floatFromInt(cell.width_px)) / scale;
    const height: f32 = @as(f32, @floatFromInt(cell.height_px)) / scale;
    return .{
        .x = @as(f32, @floatFromInt((@as(u32, col) + self.sidebarOriginColumns()) * cell.width_px)) / scale + width / 2,
        .y = @as(f32, @floatFromInt(@as(u32, row) * cell.height_px)) / scale + height / 2,
    };
}

/// Put a pointer button into SDL's queue and wait until the app has handled it.
///
/// Returns whether it came back. A posted event is delivered when the queue is
/// pumped, so a measurement taken without waiting measures an event that has
/// not happened yet — the same trap `--scroll-test` records for the wheel.
fn postButton(self: *App, io: Io, out: *Writer, button: platform.PointerButton) !bool {
    try self.window.postPointerButton(button);
    return pumpUntil(self, io, out, .pointer_button, self_test_event_budget_ms);
}

/// Put a pointer motion into SDL's queue and wait until the app has handled it.
fn postMotion(self: *App, io: Io, out: *Writer, motion: platform.PointerMotion) !bool {
    try self.window.postPointerMotion(motion);
    return pumpUntil(self, io, out, .pointer_motion, self_test_event_budget_ms);
}

/// Print one failed check and count it, so a run that fails says which one.
fn mouseCheckFailed(out: *Writer, failures: *usize, comptime format: []const u8, args: anytype) void {
    out.print("mouse-test: FAIL " ++ format ++ "\n", args) catch {};
    failures.* += 1;
}

/// Row `row` of the grid as the terminal holds it, into the caller's buffer.
///
/// Read out of the grid rather than out of the text this file fed it, so a
/// check says which text it expects to find selected instead of trusting that
/// it wrote the line it thinks it wrote. Blank cells come back as NUL, which is
/// the cell's own codepoint and never part of an expectation.
fn gridRow(self: *const App, row: u16, buffer: []u8) []const u8 {
    const live = self.activeLiveConst();
    const size = live.terminalConst().gridSize();
    var len: usize = 0;
    var col: u16 = 0;
    while (col < size.cols) : (col += 1) {
        const cell = live.terminalConst().cell(.{ .row = row, .col = col }) orelse continue;
        if (cell.wide_tail) continue;
        const written = std.unicode.utf8Encode(cell.codepoint, buffer[len..]) catch break;
        len += written;
    }
    return buffer[0..len];
}

/// Write bytes as an escaped string, so a mouse report is readable in the
/// check's own output instead of being a bare count.
fn writeEscaped(out: *Writer, bytes: []const u8) !void {
    for (bytes) |byte| {
        switch (byte) {
            0x1b => try out.writeAll("\\e"),
            '\r' => try out.writeAll("\\r"),
            '\n' => try out.writeAll("\\n"),
            else => if (byte >= 0x20 and byte < 0x7f)
                try out.writeByte(byte)
            else
                try out.print("\\x{x:0>2}", .{byte}),
        }
    }
}

/// Check that pointer presses, drags, and repeated clicks reach the terminal
/// through the real event path, and that Shift takes the pointer from a program.
///
/// Every pointer event goes in through `Window.postPointerButton` and
/// `postPointerMotion`, so the path under test is the one a hand takes: SDL's
/// own queue, `Window.pump`, `translate`, `App.handle`, `input.pointerButton`
/// and `pointerMotion`, `term.pointerEvent`, and from there either the bytes
/// the app owes the child or the selection the user gets. Nothing here calls
/// the terminal directly, so a break anywhere in that chain fails this run.
///
/// There is no child (`wantsChild`): the mouse mode is turned on by feeding the
/// exact bytes `vim` sends, so the run measures the chain rather than how fast
/// a program can print. What it prints about the program's half is the byte
/// count and content staged in `child_input`, which is the one buffer
/// `pumpChild` writes to a child from; a real program's receipt of those bytes
/// is proved in `term`, which drives `vim` and `tmux` over a pty and watches
/// them act on it.
fn mouseTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    const grid = self.activeLive().terminal().gridSize();
    const cell = self.fonts.metrics().cell;

    // 1. Real output to point at: one numbered line per row, so a selection read
    //    back says which line it came from rather than "some text".
    var feed: [64]u8 = undefined;
    for (1..mouse_test_lines + 1) |n| {
        self.activeLive().terminal().feed(try std.fmt.bufPrint(
            &feed,
            "\x1b[{d};1Hconduit-mouse-{d} alpha bravo charlie\r\n",
            .{ n, n },
        ));
    }
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    try self.activeLive().terminal().refresh(self.allocator);

    var row_buffer: [256]u8 = undefined;
    const row_text = gridRow(self, mouse_test_row, &row_buffer);
    out.print(
        "mouse-test: grid {d}x{d} of {d}x{d}px cells, row {d} reads '",
        .{ grid.cols, grid.rows, cell.width_px, cell.height_px, mouse_test_row },
    ) catch {};
    try out.writeAll(row_text);
    out.writeAll("'\n") catch {};

    // 2. The program takes the mouse, with vim's own bytes rather than modes set
    //    by hand.
    self.activeLive().terminal().feed(mouse_test_capture);
    try self.activeLive().terminal().refresh(self.allocator);
    out.print(
        "mouse-test: the program asked for {s} events, encoded as {s}\n",
        .{ @tagName(self.activeLive().terminal().mouseTracking()), @tagName(self.activeLive().terminal().mouseFormat()) },
    ) catch {};
    if (self.activeLive().terminal().mouseTracking() != .drag) {
        mouseCheckFailed(out, &failures, "the program's mouse mode did not take", .{});
    }

    const from = cellPosition(self, mouse_test_drag_from, mouse_test_row);
    const to = cellPosition(self, mouse_test_drag_to, mouse_test_row);
    var report: [32]u8 = undefined;

    // 3. Unshifted: the program's. The press must become the SGR report for the
    //    cell under the pointer — one-based column and row, as the protocol
    //    counts — compared as bytes rather than as a length.
    self.child_input.len = 0;
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = from.x,
        .y = from.y,
    })) mouseCheckFailed(out, &failures, "the press never came back through SDL", .{});
    const want_press = try std.fmt.bufPrint(
        &report,
        "\x1b[<0;{d};{d}M",
        .{ mouse_test_drag_from + 1, mouse_test_row + 1 },
    );
    out.print("mouse-test: unshifted press at column {d} row {d} sent ", .{
        mouse_test_drag_from,
        mouse_test_row,
    }) catch {};
    try writeEscaped(out, self.child_input.slice());
    out.print(" ({d} byte(s))\n", .{self.child_input.len}) catch {};
    if (!std.mem.eql(u8, self.child_input.slice(), want_press)) {
        mouseCheckFailed(out, &failures, "the press was not the SGR report for that cell", .{});
    }
    if (self.activeLive().terminal().hasSelection()) {
        mouseCheckFailed(out, &failures, "an unshifted press selected something for the user", .{});
    }

    // 4. Unshifted motion with the button held: still the program's, and the
    //    report carries the 32 bit that is what distinguishes a drag from a
    //    click in the format vim reads.
    self.child_input.len = 0;
    if (!try postMotion(self, io, out, .{
        .buttons = .{ .left = true },
        .x = to.x,
        .y = to.y,
    })) mouseCheckFailed(out, &failures, "the motion never came back through SDL", .{});
    const want_drag = try std.fmt.bufPrint(
        &report,
        "\x1b[<32;{d};{d}M",
        .{ mouse_test_drag_to + 1, mouse_test_row + 1 },
    );
    out.writeAll("mouse-test: unshifted drag sent ") catch {};
    try writeEscaped(out, self.child_input.slice());
    out.writeAll("\n") catch {};
    if (!std.mem.eql(u8, self.child_input.slice(), want_drag)) {
        mouseCheckFailed(out, &failures, "the drag was not the motion report for that cell", .{});
    }

    // 5. Shift: the user's, in both directions. The press is theirs and the drag
    //    is theirs, and the program is told nothing at all — `child_input` empty
    //    is the claim, because that is the buffer the app would write to a
    //    child from.
    const shift: platform.Mods = .{ .shift = true };
    self.child_input.len = 0;
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .mods = shift,
        .x = from.x,
        .y = from.y,
    })) mouseCheckFailed(out, &failures, "the shifted press never came back through SDL", .{});
    if (self.child_input.len != 0) {
        mouseCheckFailed(out, &failures, "a shifted press was reported to the program", .{});
    }
    self.child_input.len = 0;
    if (!try postMotion(self, io, out, .{
        .buttons = .{ .left = true },
        .mods = shift,
        .x = to.x,
        .y = to.y,
    })) mouseCheckFailed(out, &failures, "the shifted motion never came back through SDL", .{});
    if (self.child_input.len != 0) {
        mouseCheckFailed(out, &failures, "a shifted drag was reported to the program", .{});
    }
    self.child_input.len = 0;
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .mods = shift,
        .x = to.x,
        .y = to.y,
    });
    if (self.child_input.len != 0) {
        mouseCheckFailed(out, &failures, "a shifted release was reported to the program", .{});
    }
    if (!self.activeLive().terminal().hasSelection()) {
        mouseCheckFailed(out, &failures, "a shifted drag selected nothing", .{});
    }

    // What the user got, read back out of the engine. The expectation is the
    // row's own text between the two columns, minus the cell the pointer is
    // over: a drag reads as "up to where I am".
    const selected = (try self.activeLive().terminal().selectionText(self.allocator)) orelse {
        mouseCheckFailed(out, &failures, "the selection has no text", .{});
        return 1;
    };
    defer self.allocator.free(selected);
    const expected = row_text[mouse_test_drag_from..mouse_test_drag_to];
    out.print("mouse-test: shifted drag selected {d} byte(s), '", .{selected.len}) catch {};
    try out.writeAll(selected);
    out.writeAll("'\n") catch {};
    if (!std.mem.eql(u8, selected, expected)) {
        mouseCheckFailed(out, &failures, "the selection is not the text between the two cells", .{});
    }

    // 6. Shift released: the program owns the pointer again, on the very next
    //    event. An override that latched would leave the user unable to give
    //    the mouse back without releasing the button first.
    //
    //    The pointer moves to a *different* cell first, because that is a real
    //    requirement and a real one: upstream's encoder drops a motion that
    //    lands in the cell the last motion landed in, which is what keeps a
    //    resting mouse from filling a program's input with identical reports.
    //    Asking for a report from a pointer that has not moved would be asking
    //    for the dedup to fail.
    const elsewhere = cellPosition(self, mouse_test_drag_to + 2, mouse_test_row);
    self.child_input.len = 0;
    if (!try postMotion(self, io, out, .{
        .buttons = .{ .left = true },
        .x = elsewhere.x,
        .y = elsewhere.y,
    })) mouseCheckFailed(out, &failures, "the unshifted motion after the drag never arrived", .{});
    if (self.child_input.len == 0) {
        mouseCheckFailed(out, &failures, "releasing Shift did not give the pointer back", .{});
    }
    out.writeAll("mouse-test: with Shift released the drag went to the program again (") catch {};
    try writeEscaped(out, self.child_input.slice());
    out.writeAll(")\n") catch {};

    // 7. The selection is drawn. The capture is the app's reused readback
    //    buffer, so the first one is copied out before anything reads it again.
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const before_selection = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(before_selection);
    const selection_color = gridColors(default_palette).selection;
    const lit = countPixels(try self.capture(), selection_color);
    out.print(
        "mouse-test: {d} pixel(s) of {d}x{d} are the selection colour {d},{d},{d}\n",
        .{ lit, self.size.width, self.size.height, selection_color.r, selection_color.g, selection_color.b },
    ) catch {};
    if (lit == 0) {
        mouseCheckFailed(out, &failures, "the selection is not drawn on the surface", .{});
    }

    // 8. The selection survives scrolling. The wheel goes in through SDL like
    //    every other event, and the claim is that the same selection is still
    //    selected afterwards — the text unchanged and the highlight moved down
    //    the screen with the rows it covers.
    if (!try postWheelEvent(self, io, out, 2)) {
        mouseCheckFailed(out, &failures, "the wheel never came back through SDL", .{});
    }
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const scrolled = self.activeLive().terminal().viewport();
    const after_scroll = (try self.activeLive().terminal().selectionText(self.allocator)) orelse {
        mouseCheckFailed(out, &failures, "scrolling cleared the selection", .{});
        return 1;
    };
    defer self.allocator.free(after_scroll);
    out.print(
        "mouse-test: {d} row(s) back into history, the selection is still {d} byte(s)",
        .{ scrolled.offset, after_scroll.len },
    ) catch {};
    if (!std.mem.eql(u8, after_scroll, selected)) {
        mouseCheckFailed(out, &failures, "scrolling changed what is selected", .{});
    }
    const lit_after = countPixels(try self.capture(), selection_color);
    const moved = countDifferingPixels(before_selection, try self.capture());
    out.print(", {d} pixel(s) of it are still lit, {d} pixel(s) differ on the surface\n", .{
        lit_after,
        moved,
    }) catch {};
    if (lit_after == 0) {
        mouseCheckFailed(out, &failures, "the highlight did not follow the rows it covers", .{});
    }

    // 9. New output does not clear a selection: the pins are tracked, so a
    //    program printing under a selection leaves it where it was.
    self.activeLive().terminal().feed("\r\nconduit-mouse-newer\r\nconduit-mouse-newer\r\n");
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const after_output = (try self.activeLive().terminal().selectionText(self.allocator)) orelse {
        mouseCheckFailed(out, &failures, "new output cleared the selection", .{});
        return 1;
    };
    defer self.allocator.free(after_output);
    out.print("mouse-test: after two more lines of output the selection is still ", .{}) catch {};
    try out.writeAll(after_output);
    out.writeAll("\n") catch {};
    if (!std.mem.eql(u8, after_output, selected)) {
        mouseCheckFailed(out, &failures, "new output changed what is selected", .{});
    }

    // 10. The program gives the mouse back, with the three DECRSTs it would
    //     send, and the pointer goes back to the user without Shift at all.
    self.activeLive().terminal().feed(mouse_test_release);
    try self.activeLive().terminal().refresh(self.allocator);
    out.print(
        "mouse-test: the program gave the mouse back; tracking is now {s}\n",
        .{@tagName(self.activeLive().terminal().mouseTracking())},
    ) catch {};
    if (self.activeLive().terminal().pointerOwner(.{}) != .user) {
        mouseCheckFailed(out, &failures, "the pointer did not go back to the user", .{});
    }

    // 11. A click on an empty cell dismisses the selection: a click on its own
    //     selects nothing, and nothing selected is what it leaves behind.
    const empty = cellPosition(self, 2, grid.rows - 1);
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = empty.x,
        .y = empty.y,
    })) mouseCheckFailed(out, &failures, "the dismissing click never came back through SDL", .{});
    if (self.activeLive().terminal().hasSelection()) {
        mouseCheckFailed(out, &failures, "a click on an empty cell left a selection behind", .{});
    }

    // 12. And a fresh drag, so the frame the run leaves behind — the one a
    //     `--screenshot` writes — shows a selection drawn on real text.
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = from.x,
        .y = from.y,
    })) mouseCheckFailed(out, &failures, "the closing press never came back through SDL", .{});
    if (!try postMotion(self, io, out, .{
        .buttons = .{ .left = true },
        .x = to.x,
        .y = to.y,
    })) mouseCheckFailed(out, &failures, "the closing motion never came back through SDL", .{});
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = to.x,
        .y = to.y,
    })) mouseCheckFailed(out, &failures, "the closing release never came back through SDL", .{});
    if (!self.activeLive().terminal().hasSelection()) {
        mouseCheckFailed(out, &failures, "the closing drag selected nothing", .{});
    }

    // 13. Find a word in the grid as it stands after the scroll and new output,
    //     rather than assuming those deliberately disruptive operations left a
    //     particular logical line at its original viewport row. All test text
    //     is ASCII, so the byte offset of `bravo` is also its terminal column.
    const word = "bravo";
    var click_row: ?u16 = null;
    var click_col: usize = 0;
    var line_buffer: [256]u8 = undefined;
    var line_len: usize = 0;
    var candidate_buffer: [256]u8 = undefined;
    var candidate_row: u16 = 0;
    while (candidate_row < grid.rows) : (candidate_row += 1) {
        const candidate = gridRow(self, candidate_row, &candidate_buffer);
        if (std.mem.indexOf(u8, candidate, word)) |col| {
            click_row = candidate_row;
            click_col = col;
            line_len = candidate.len;
            @memcpy(line_buffer[0..line_len], candidate);
            break;
        }
    }
    const known_row = click_row orelse {
        mouseCheckFailed(out, &failures, "no visible known row contains '{s}'", .{word});
        return 1;
    };
    const known_line = std.mem.trim(u8, line_buffer[0..line_len], "\x00 \t");
    const word_at = cellPosition(self, @intCast(click_col), known_row);

    // A real triple-click is three press/release pairs at one position. Each
    // event is posted and awaited separately, and the clock bounds the entire
    // run through the third press. If that whole span is at most 500ms, the
    // timestamps used by each intervening App.handle call necessarily satisfy
    // the gesture's repeat interval without a sleep or a bypass around SDL.
    const click_started_ns = Io.Clock.real.now(io).nanoseconds;
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = word_at.x,
        .y = word_at.y,
    })) mouseCheckFailed(out, &failures, "the first word press never came back through SDL", .{});
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = word_at.x,
        .y = word_at.y,
    })) mouseCheckFailed(out, &failures, "the first word release never came back through SDL", .{});
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = word_at.x,
        .y = word_at.y,
    })) mouseCheckFailed(out, &failures, "the second word press never came back through SDL", .{});

    const selected_word = (try self.activeLive().terminal().selectionText(self.allocator)) orelse {
        mouseCheckFailed(out, &failures, "the double-click selected no word", .{});
        return 1;
    };
    defer self.allocator.free(selected_word);
    out.writeAll("mouse-test: double-click selected '") catch {};
    try out.writeAll(selected_word);
    out.writeAll("'\n") catch {};
    if (!std.mem.eql(u8, selected_word, word)) {
        mouseCheckFailed(out, &failures, "the double-click did not select exactly '{s}'", .{word});
    }

    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = word_at.x,
        .y = word_at.y,
    })) mouseCheckFailed(out, &failures, "the second word release never came back through SDL", .{});
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = word_at.x,
        .y = word_at.y,
    })) mouseCheckFailed(out, &failures, "the third word press never came back through SDL", .{});
    const click_finished_ns = Io.Clock.real.now(io).nanoseconds;
    const click_span_ns = click_finished_ns - click_started_ns;
    out.print(
        "mouse-test: click presses used real-clock interval [{d}, {d}], span {d}ns\n",
        .{ click_started_ns, click_finished_ns, click_span_ns },
    ) catch {};
    if (click_span_ns < 0 or click_span_ns > 500 * std.time.ns_per_ms) {
        mouseCheckFailed(out, &failures, "the three clicks exceeded the 500ms repeat interval", .{});
    }

    const selected_line = (try self.activeLive().terminal().selectionText(self.allocator)) orelse {
        mouseCheckFailed(out, &failures, "the triple-click selected no line", .{});
        return 1;
    };
    defer self.allocator.free(selected_line);
    out.writeAll("mouse-test: triple-click selected '") catch {};
    try out.writeAll(selected_line);
    out.writeAll("'\n") catch {};
    if (!std.mem.eql(u8, selected_line, known_line)) {
        mouseCheckFailed(out, &failures, "the triple-click did not select the trimmed known line", .{});
    }
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = word_at.x,
        .y = word_at.y,
    })) mouseCheckFailed(out, &failures, "the third word release never came back through SDL", .{});

    // The final selection is the triple-click's line, so the screenshot proves
    // that the result of the real repeated-click chain is drawn on the surface.
    try self.drawFrame();
    out.print("mouse-test: {d} failure(s)\n", .{failures}) catch {};

    try self.window.postCloseRequest();
    if (!try pumpUntil(self, io, out, .close, self_test_event_budget_ms)) {
        out.flush() catch {};
        return error.SelfTestCloseNotDelivered;
    }
    return if (failures == 0) 0 else 1;
}

/// The line `--clipboard-test`'s child prints first: real text on the screen
/// for the check to select, made of words no log line could contain by chance.
const clipboard_test_line = "conduit-clipboard kestrel lantern";

/// What the check selects on that line, copies, and pastes back.
const clipboard_test_selection = "kestrel lantern";

/// The bytes a bracketed paste of the selection must be, exactly.
const clipboard_test_bracketed = "\x1b[200~" ++ clipboard_test_selection ++ "\x1b[201~";

/// The child `--clipboard-test` runs, as `/bin/sh -c` gets it.
///
/// It puts the tty in raw mode with ISIG kept on, so every byte the app writes
/// arrives unaltered *and* Ctrl+C is still the interrupt. Then it does what a
/// shell does around a paste: turns bracketed paste on (DECSET 2004, as bash
/// does at its prompt), reads exactly the bytes a bracketed paste of the
/// selection is and prints them back as hex, turns bracketed paste off, and
/// reads the exact remaining fixture bytes and prints them as hex. It then
/// execs one blocking reader, so Ctrl+C always targets the tracked child
/// directly rather than catching a shell between short-lived pipelines. What
/// the child prints is what it received, so the check reads the program's side
/// of the pipe rather than the app's.
const clipboard_test_script = std.fmt.comptimePrint(
    "stty raw -echo isig; " ++
        "printf '{s}\\r\\n\\033[?2004hREADY1\\r\\n'; " ++
        "dd bs=1 count={d} 2>/dev/null | od -An -tx1 -v | tr -d '\\n'; " ++
        "printf '\\r\\n\\033[?2004lREADY2\\r\\n'; " ++
        "dd bs=1 count={d} 2>/dev/null | od -An -tx1 -v | tr -d '\\n'; " ++
        "printf '\\r\\nREADY3\\r\\n'; " ++
        "trap - INT; exec dd bs=1 count=1 of=/dev/null 2>/dev/null",
    .{
        clipboard_test_line,
        clipboard_test_bracketed.len,
        clipboard_test_primary.len + 1 +
            ("\x1b]52;c;" ++ clipboard_test_osc_read_b64 ++ "\x1b\\").len +
            2 * "\x1b]52;c;\x1b\\".len,
    },
);

/// How long the check waits for the child to do one thing, in milliseconds.
const clipboard_test_budget_ms: i64 = 5000;

/// The fixtures the check puts on a clipboard, and their base64 forms as an
/// OSC 52 reply carries them. None of them may appear in the log.
const clipboard_test_primary = "conduit-primary-fixture";
const clipboard_test_multiline = "echo conduit-one\necho conduit-two\n";
const clipboard_test_osc_write = "conduit-osc52-write";
const clipboard_test_osc_write_b64 = "Y29uZHVpdC1vc2M1Mi13cml0ZQ==";
const clipboard_test_osc_read = "conduit-osc52-read";
const clipboard_test_osc_read_b64 = "Y29uZHVpdC1vc2M1Mi1yZWFk";
const clipboard_test_untouched = "conduit-clipboard-untouched";
const clipboard_test_secrets = [_][]const u8{
    clipboard_test_selection,     clipboard_test_primary,
    "conduit-one",                clipboard_test_osc_write,
    clipboard_test_osc_write_b64, clipboard_test_osc_read,
    clipboard_test_osc_read_b64,  clipboard_test_untouched,
};

/// Report one claim, counting it when it did not hold.
fn clipCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("clipboard-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

/// Print `label`, then `bytes` escaped, so every byte is in the output.
fn writeBytes(out: *Writer, label: []const u8, bytes: []const u8) void {
    out.print("clipboard-test:      {s} ({d} byte(s)): '", .{ label, bytes.len }) catch {};
    writeEscaped(out, bytes) catch {};
    out.writeAll("'\n") catch {};
}

/// Press and release a key through SDL's queue, waiting for each to be handled.
fn postKey(self: *App, io: Io, out: *Writer, codepoint: u21, mods: platform.Mods) !bool {
    if (!try postKeyAction(self, io, out, codepoint, mods, .press)) return false;
    return postKeyAction(self, io, out, codepoint, mods, .release);
}

fn postNamedKey(self: *App, io: Io, out: *Writer, key: platform.Key, mods: platform.Mods) !bool {
    try self.window.postNamedKey(key, mods, .press);
    if (!try pumpUntil(self, io, out, .key, self_test_event_budget_ms)) return false;
    try self.window.postNamedKey(key, mods, .release);
    return pumpUntil(self, io, out, .key, self_test_event_budget_ms);
}

fn postKeyAction(
    self: *App,
    io: Io,
    out: *Writer,
    codepoint: u21,
    mods: platform.Mods,
    action: platform.KeyAction,
) !bool {
    try self.window.postCharacterKey(codepoint, mods, action);
    return pumpUntil(self, io, out, .key, self_test_event_budget_ms);
}

/// Drag across columns `from` to `to` of `row` with the left button, through
/// SDL's queue. The selection stops before the cell the pointer ends over.
fn dragAcross(self: *App, io: Io, out: *Writer, row: u16, from: u16, to: u16) !bool {
    const start = cellPosition(self, from, row);
    const end = cellPosition(self, to, row);
    if (!try postButton(self, io, out, .{ .button = .left, .action = .press, .x = start.x, .y = start.y })) return false;
    if (!try postMotion(self, io, out, .{ .buttons = .{ .left = true }, .x = end.x, .y = end.y })) return false;
    return postButton(self, io, out, .{ .button = .left, .action = .release, .x = end.x, .y = end.y });
}

/// Pump the child until what it printed contains `needle`, or the budget runs
/// out, or it exits. Blocks on the child's own readiness, never on a timer.
fn waitForChildText(self: *App, io: Io, needle: []const u8) !bool {
    const trace = self.trace.?;
    const deadline = Io.Clock.real.now(io).nanoseconds + clipboard_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        try self.pumpChild();
        if (std.mem.indexOf(u8, trace.received.items, needle) != null) return true;
        const child = self.activeLive().child() orelse return false;
        if (child.state() == .exited) return false;
        const left = deadline - Io.Clock.real.now(io).nanoseconds;
        if (left <= 0) return false;
        _ = child.waitReadable(@intCast(@max(1, @divTrunc(left, std.time.ns_per_ms))));
    }
}

/// The bytes the child printed back as hex after `marker`, decoded into
/// `buffer`. A token cut in half by a read is left for the next call.
fn childEcho(self: *const App, marker: []const u8, buffer: []u8) []const u8 {
    const received = self.trace.?.received.items;
    const at = std.mem.indexOf(u8, received, marker) orelse return buffer[0..0];
    const start = at + marker.len;
    const end = std.mem.indexOfPos(u8, received, start, "\r\n") orelse received.len;
    var len: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, received[start..end], ' ');
    while (tokens.next()) |token| {
        if (token.len != 2 or len == buffer.len) break;
        buffer[len] = std.fmt.parseInt(u8, token, 16) catch break;
        len += 1;
    }
    return buffer[0..len];
}

/// Pump until the child has echoed at least `want` bytes after `marker`.
fn waitForEcho(self: *App, io: Io, marker: []const u8, want: usize, buffer: []u8) ![]const u8 {
    const deadline = Io.Clock.real.now(io).nanoseconds + clipboard_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        try self.pumpChild();
        const echoed = childEcho(self, marker, buffer);
        if (echoed.len >= want) return echoed;
        const child = self.activeLive().child() orelse return echoed;
        if (child.state() == .exited) return echoed;
        const left = deadline - Io.Clock.real.now(io).nanoseconds;
        if (left <= 0) return echoed;
        _ = child.waitReadable(@intCast(@max(1, @divTrunc(left, std.time.ns_per_ms))));
    }
}

/// Pump until the child has exited, or the budget runs out.
fn waitForChildExit(self: *App, io: Io) !?pty.ChildState {
    const child = self.activeLive().child() orelse return null;
    const deadline = Io.Clock.real.now(io).nanoseconds + clipboard_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        try self.pumpChild();
        const state = child.state();
        if (state == .exited) return state;
        const left = deadline - Io.Clock.real.now(io).nanoseconds;
        if (left <= 0) return null;
        // Readiness or the next slice of the budget, whichever is first: an
        // exit with no output last makes nothing readable, so the state is
        // asked again rather than waited on for the whole budget.
        _ = child.waitReadable(@intCast(@min(@as(i128, 50), @max(1, @divTrunc(left, std.time.ns_per_ms)))));
    }
}

/// The row of the grid `needle` is on, and the column it starts at.
fn findOnGrid(self: *App, needle: []const u8) !?struct { row: u16, col: u16 } {
    try self.activeLive().terminal().refresh(self.allocator);
    var buffer: [1024]u8 = undefined;
    var row: u16 = 0;
    while (row < self.activeLive().terminal().gridSize().rows) : (row += 1) {
        const text = gridRow(self, row, &buffer);
        if (std.mem.indexOf(u8, text, needle)) |col| return .{ .row = row, .col = @intCast(col) };
    }
    return null;
}

/// The standard clipboard's text, for a check to compare. Fixtures only.
fn clipboardNow(self: *App) ![]u8 {
    return platform.getClipboardText(self.allocator);
}

/// Feed bytes as the running program would have written them, then handle
/// what they produced exactly as `pumpChild` does: note the events, and write
/// the terminal's answers to the child through the one write site.
///
/// The OSC 52 requests are fed rather than printed by the child, the same way
/// `--mouse-test` feeds `vim`'s mode bytes: the claim is about what the
/// terminal does with the request, and the reply still goes to the real child
/// and is read back from it.
fn feedAsProgram(self: *App, bytes: []const u8) !void {
    self.activeLive().terminal().feed(bytes);
    for (self.activeLive().terminal().takeEvents()) |event| self.noteTerminalEvent(self.activeLive(), event);
    try self.flushToChild();
}

/// Check copy, paste, bracketed paste, middle-click primary paste, the Ctrl+C
/// rule and the OSC 52 policies, end to end, on clipboards nobody else owns.
///
/// The run is pinned to SDL's `offscreen` driver (`runApp`), whose clipboard
/// and primary selection are SDL's own process-local copies, and it refuses
/// to start on any other: a check that writes fixtures must never reach the
/// clipboard of a display a person is using. What that costs is said in the
/// output — the X11/Wayland backends behind the same calls are not exercised.
///
/// Every gesture goes in through SDL's queue (`postCharacterKey`,
/// `postPointerButton`) and through `App.handle`, so the path is the one a
/// hand takes. Every byte for the child goes out through `flushToChild` and is
/// recorded as it is written; the child prints back what it read, so each
/// paste is shown twice — what the app wrote, and what the program received.
fn clipboardTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    var trace: ClipboardTrace = .{};
    defer trace.deinit(self.allocator);
    self.trace = &trace;
    defer self.trace = null;

    out.print("clipboard-test: video driver {s}; clipboards are SDL's process-local ones, not the display's\n", .{
        platform.videoDriverName() orelse "(none)",
    }) catch {};

    // 0. The child, started on a worker by `App.init`, collected here.
    if (self.activePresentation().load) |job| {
        if (job.thread) |thread| thread.join();
        job.thread = null;
    }
    _ = self.pollLoad();
    if (self.activeLive().child() == null) {
        clipCheck(out, &failures, false, "the child did not start", .{});
        out.flush() catch {};
        return 1;
    }
    const ready = try waitForChildText(self, io, "READY1\r\n");
    clipCheck(out, &failures, ready, "the child printed its line and enabled bracketed paste", .{});
    if (!ready) return 1;
    clipCheck(out, &failures, self.activeLive().terminal().bracketedPasteEnabled(), "mode 2004 is on, set by the program", .{});

    // 1. Copy a real selection with the copy chord, and read it back.
    try self.drawFrame();
    const line = (try findOnGrid(self, clipboard_test_line)) orelse {
        clipCheck(out, &failures, false, "the child's line is not on the grid", .{});
        return 1;
    };
    const from: u16 = line.col + @as(u16, @intCast(clipboard_test_line.len - clipboard_test_selection.len));
    const to: u16 = from + @as(u16, @intCast(clipboard_test_selection.len));
    if (!try dragAcross(self, io, out, line.row, from, to)) clipCheck(out, &failures, false, "the drag never came back through SDL", .{});
    const chord: platform.Mods = .{ .ctrl = true, .shift = true };
    var mark = trace.sent.items.len;
    const dispatches_before_copy = self.action_dispatch_count;
    if (!try postKey(self, io, out, 'c', chord)) clipCheck(out, &failures, false, "Ctrl+Shift+C never came back through SDL", .{});
    const copied = try clipboardNow(self);
    defer self.allocator.free(copied);
    writeBytes(out, "Ctrl+Shift+C with a selection put on the clipboard", copied);
    clipCheck(out, &failures, std.mem.eql(u8, copied, clipboard_test_selection), "the clipboard reads back the selection", .{});
    clipCheck(out, &failures, trace.sent.items.len == mark, "the copy chord sent the program nothing ({d} byte(s))", .{trace.sent.items.len - mark});
    clipCheck(out, &failures, self.action_dispatch_count == dispatches_before_copy + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", clipboard_copy_action), "the copy chord invoked clipboard.copy through the registry exactly once", .{});

    // 2. Paste it with the paste chord while the program has mode 2004 on.
    mark = trace.sent.items.len;
    const dispatches_before_paste = self.action_dispatch_count;
    if (!try postKey(self, io, out, 'v', chord)) clipCheck(out, &failures, false, "Ctrl+Shift+V never came back through SDL", .{});
    const pasted = trace.sent.items[mark..];
    writeBytes(out, "Ctrl+Shift+V wrote to the child", pasted);
    clipCheck(out, &failures, std.mem.eql(u8, pasted, clipboard_test_bracketed), "the paste is the selection between ESC[200~ and ESC[201~", .{});
    clipCheck(out, &failures, self.action_dispatch_count == dispatches_before_paste + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", clipboard_paste_action), "the paste chord invoked clipboard.paste through the registry exactly once", .{});
    var echo_buffer: [512]u8 = undefined;
    const echoed = try waitForEcho(self, io, "READY1\r\n", clipboard_test_bracketed.len, &echo_buffer);
    writeBytes(out, "the child read", echoed);
    clipCheck(out, &failures, std.mem.eql(u8, echoed, clipboard_test_bracketed), "the child received exactly those bytes", .{});

    // From here the child prints every byte back, after this marker.
    const phase_two = "READY2\r\n";
    const off = try waitForChildText(self, io, phase_two);
    clipCheck(out, &failures, off and !self.activeLive().terminal().bracketedPasteEnabled(), "the program turned mode 2004 off", .{});
    var expected_echo: std.ArrayList(u8) = .empty;
    defer expected_echo.deinit(self.allocator);

    // 3. Middle click pastes the primary selection.
    try platform.setPrimarySelectionText(self.allocator, clipboard_test_primary);
    const anywhere = cellPosition(self, 2, line.row);
    mark = trace.sent.items.len;
    if (!try postButton(self, io, out, .{ .button = .middle, .action = .press, .x = anywhere.x, .y = anywhere.y })) clipCheck(out, &failures, false, "the middle press never came back through SDL", .{});
    if (!try postButton(self, io, out, .{ .button = .middle, .action = .release, .x = anywhere.x, .y = anywhere.y })) clipCheck(out, &failures, false, "the middle release never came back through SDL", .{});
    const middle = trace.sent.items[mark..];
    writeBytes(out, "middle click wrote to the child", middle);
    clipCheck(out, &failures, std.mem.eql(u8, middle, clipboard_test_primary), "the middle click pasted the primary selection, unbracketed", .{});
    try expected_echo.appendSlice(self.allocator, clipboard_test_primary);

    // 4. A multi-line paste with mode 2004 off is not sent at all. The key
    //    after it is the proof on the child's side: it is the next byte the
    //    program reads.
    try platform.setClipboardText(self.allocator, clipboard_test_multiline);
    mark = trace.sent.items.len;
    if (!try postKey(self, io, out, 'v', chord)) clipCheck(out, &failures, false, "the second Ctrl+Shift+V never came back through SDL", .{});
    clipCheck(out, &failures, trace.sent.items.len == mark, "a {d}-byte, two-line paste with mode 2004 off sent nothing ({d} byte(s))", .{ clipboard_test_multiline.len, trace.sent.items.len - mark });
    const dispatches_before_unbound = self.action_dispatch_count;
    if (!try postKey(self, io, out, 'z', .{})) clipCheck(out, &failures, false, "the z key never came back through SDL", .{});
    try expected_echo.append(self.allocator, 'z');
    const after_refusal = trace.sent.items[mark..];
    writeBytes(out, "the unbound z written after the refused paste", after_refusal);
    clipCheck(out, &failures, std.mem.eql(u8, after_refusal, "z") and
        self.action_dispatch_count == dispatches_before_unbound, "the unbound z reached the PTY byte-for-byte without dispatching an action", .{});

    // 5. OSC 52 under each policy, with the program's exact bytes.
    const osc_write = "\x1b]52;c;" ++ clipboard_test_osc_write_b64 ++ "\x1b\\";
    const osc_read = "\x1b]52;c;?\x1b\\";
    const policies = [_]term.ClipboardPolicy{ .allow, .ask, .deny };
    for (policies) |policy| {
        try platform.setClipboardText(self.allocator, clipboard_test_untouched);
        trace.last_permission = null;
        self.activeLive().terminal().setClipboardPolicies(.{ .read = .deny, .write = policy });
        mark = trace.sent.items.len;
        try feedAsProgram(self, osc_write);
        const now = try clipboardNow(self);
        defer self.allocator.free(now);
        const diagnostic = self.activeLive().terminal().lastClipboardRequest();
        out.print("clipboard-test:      write policy {s}: program sent '", .{@tagName(policy)}) catch {};
        writeEscaped(out, osc_write) catch {};
        out.print("'; logged '{?f}'\n", .{diagnostic}) catch {};
        const want: []const u8 = if (policy == .allow) clipboard_test_osc_write else clipboard_test_untouched;
        clipCheck(out, &failures, std.mem.eql(u8, now, want), "OSC 52 write under {s}: the clipboard holds the {s} text", .{
            @tagName(policy), if (policy == .allow) "program's" else "untouched",
        });
        clipCheck(out, &failures, trace.sent.items.len == mark, "OSC 52 write under {s}: no reply ({d} byte(s))", .{ @tagName(policy), trace.sent.items.len - mark });
        const asked = trace.last_permission;
        const want_ask = policy == .ask;
        clipCheck(out, &failures, (asked != null) == want_ask and (!want_ask or
            std.meta.eql(asked.?, term.PermissionRequest{ .operation = .write, .location = .standard, .byte_count = clipboard_test_osc_write.len })), "OSC 52 write under {s}: {s}", .{
            @tagName(policy), if (want_ask) "a permission event, write/standard/19 bytes, no contents" else "no permission event",
        });
    }
    for (policies) |policy| {
        try platform.setClipboardText(self.allocator, clipboard_test_osc_read);
        trace.last_permission = null;
        self.activeLive().terminal().setClipboardPolicies(.{ .read = policy, .write = .deny });
        mark = trace.sent.items.len;
        try feedAsProgram(self, osc_read);
        const reply = trace.sent.items[mark..];
        const want: []const u8 = if (policy == .allow) "\x1b]52;c;" ++ clipboard_test_osc_read_b64 ++ "\x1b\\" else "\x1b]52;c;\x1b\\";
        out.print("clipboard-test:      read policy {s}: program sent '", .{@tagName(policy)}) catch {};
        writeEscaped(out, osc_read) catch {};
        out.print("'; logged '{?f}'\n", .{self.activeLive().terminal().lastClipboardRequest()}) catch {};
        writeBytes(out, "  the terminal replied", reply);
        clipCheck(out, &failures, std.mem.eql(u8, reply, want), "OSC 52 read under {s}: {s}", .{
            @tagName(policy), if (policy == .allow) "the clipboard, base64" else "an empty reply",
        });
        try expected_echo.appendSlice(self.allocator, want);
        const asked = trace.last_permission;
        const want_ask = policy == .ask;
        clipCheck(out, &failures, (asked != null) == want_ask and (!want_ask or
            std.meta.eql(asked.?, term.PermissionRequest{ .operation = .read, .location = .standard, .byte_count = null })), "OSC 52 read under {s}: {s}", .{
            @tagName(policy), if (want_ask) "a permission event, read/standard, no size" else "no permission event",
        });
    }
    const replies = try waitForEcho(self, io, phase_two, expected_echo.items.len, &echo_buffer);
    clipCheck(out, &failures, std.mem.eql(u8, replies, expected_echo.items), "the child read every reply byte for byte ({d} byte(s) since READY2)", .{replies.len});
    const final_reader_ready = try waitForChildText(self, io, "READY3\r\n");
    clipCheck(out, &failures, final_reader_ready, "the child entered its stable SIGINT reader", .{});

    // 6. Ctrl+C with a selection copies it and sends nothing; the selection
    //    goes with it, so the next Ctrl+C is the program's again. The drag
    //    starts on a different cell from the first one: a press on the same
    //    cell within the double-click interval is a double-click, which selects
    //    by word, and that is not the gesture this step is about.
    try self.drawFrame();
    if (try findOnGrid(self, clipboard_test_line)) |again| {
        const word = again.col + @as(u16, @intCast(clipboard_test_line.len - "lantern".len));
        if (!try dragAcross(self, io, out, again.row, word, word + 7)) clipCheck(out, &failures, false, "the second drag never came back through SDL", .{});
    } else clipCheck(out, &failures, false, "the child's line left the grid", .{});
    const ctrl: platform.Mods = .{ .ctrl = true };
    mark = trace.sent.items.len;
    if (!try postKey(self, io, out, 'c', ctrl)) clipCheck(out, &failures, false, "Ctrl+C never came back through SDL", .{});
    const ctrl_copied = try clipboardNow(self);
    defer self.allocator.free(ctrl_copied);
    writeBytes(out, "Ctrl+C with a selection put on the clipboard", ctrl_copied);
    clipCheck(out, &failures, std.mem.eql(u8, ctrl_copied, "lantern") and trace.sent.items.len == mark and
        !self.activeLive().terminal().hasSelection(), "Ctrl+C with a selection copied it, sent nothing, and dropped the selection", .{});

    // 7. Ctrl+C with no selection is SIGINT, and copies nothing.
    try platform.setClipboardText(self.allocator, clipboard_test_untouched);
    mark = trace.sent.items.len;
    if (!try postKey(self, io, out, 'c', ctrl)) clipCheck(out, &failures, false, "the second Ctrl+C never came back through SDL", .{});
    const interrupt = trace.sent.items[mark..];
    writeBytes(out, "Ctrl+C with no selection wrote to the child", interrupt);
    clipCheck(out, &failures, std.mem.eql(u8, interrupt, "\x03"), "Ctrl+C with no selection is the byte 0x03", .{});
    const kept = try clipboardNow(self);
    defer self.allocator.free(kept);
    clipCheck(out, &failures, std.mem.eql(u8, kept, clipboard_test_untouched), "and it copied nothing: the clipboard still holds its fixture", .{});
    const ended = try waitForChildExit(self, io);
    const by_interrupt = if (ended) |state| switch (state) {
        .exited => |status| status == .signal and status.signal == .interrupt,
        .running => false,
    } else false;
    clipCheck(out, &failures, by_interrupt, "the child died of SIGINT", .{});

    // 8. Nothing the clipboards held reached the log.
    if (sink.logPath().len == 0) {
        clipCheck(out, &failures, false, "there is no log file to search", .{});
    } else {
        const logged = try Dir.cwd().readFileAlloc(io, sink.logPath(), self.allocator, .limited(64 * 1024 * 1024));
        defer self.allocator.free(logged);
        var leaked: usize = 0;
        for (clipboard_test_secrets) |secret| {
            if (std.mem.indexOf(u8, logged, secret) != null) {
                out.print("clipboard-test: FAIL the log contains the fixture '{s}'\n", .{secret}) catch {};
                leaked += 1;
            }
        }
        clipCheck(out, &failures, leaked == 0, "{d} log byte(s) searched for {d} fixtures and their base64: none found", .{ logged.len, clipboard_test_secrets.len });
    }

    try self.drawFrame();
    out.print("clipboard-test: {d} failure(s)\n", .{failures}) catch {};
    try self.window.postCloseRequest();
    if (!try pumpUntil(self, io, out, .close, self_test_event_budget_ms)) {
        out.flush() catch {};
        return error.SelfTestCloseNotDelivered;
    }
    return if (failures == 0) 0 else 1;
}

/// Post a wheel away from the user and wait until the app has handled it.
fn postWheelEvent(self: *App, io: Io, out: *Writer, notches: f32) !bool {
    const middle = cellPosition(self, 0, 0);
    try self.window.postWheel(.{ .dy = notches, .x = middle.x, .y = middle.y });
    return pumpUntil(self, io, out, .wheel, self_test_event_budget_ms);
}

/// Print row `row` of the grid as the terminal holds it.
fn writeGridRow(out: *Writer, self: *App, row: u16) !void {
    const size = self.activeLive().terminal().gridSize();
    var col: u16 = 0;
    while (col < size.cols) : (col += 1) {
        const cell = self.activeLive().terminal().cell(.{ .row = row, .col = col }) orelse continue;
        // The tail half of a wide character carries no glyph of its own, and
        // printing it would double the character.
        if (cell.wide_tail) continue;
        var encoded: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.codepoint, &encoded) catch continue;
        try out.writeAll(encoded[0..len]);
    }
}

/// How many pixels differ between two RGBA captures of the same surface.
fn countDifferingPixels(before: []const u8, after: []const u8) usize {
    const pixels = @min(before.len, after.len) / 4;
    var differing: usize = 0;
    for (0..pixels) |i| {
        const at = i * 4;
        if (!std.mem.eql(u8, before[at .. at + 4], after[at .. at + 4])) differing += 1;
    }
    return differing;
}

fn countDifferingPixelsInRect(
    before: []const u8,
    after: []const u8,
    size: render.Size,
    rect: render.PixelRect,
) usize {
    const x_end = @min(size.width, @as(u32, @intFromFloat(rect.x + rect.width)));
    const y_end = @min(size.height, @as(u32, @intFromFloat(rect.y + rect.height)));
    var differing: usize = 0;
    var y: u32 = @intFromFloat(rect.y);
    while (y < y_end) : (y += 1) {
        var x: u32 = @intFromFloat(rect.x);
        while (x < x_end) : (x += 1) {
            const offset = (@as(usize, y) * size.width + x) * 4;
            if (offset + 4 <= before.len and offset + 4 <= after.len and
                !std.mem.eql(u8, before[offset .. offset + 4], after[offset .. offset + 4]))
            {
                differing += 1;
            }
        }
    }
    return differing;
}

fn overlayCellAt(view: render.OverlayView, position: render.OverlayPosition) ?render.OverlayCell {
    for (view.cells) |cell| {
        if (cell.position.col == position.col and cell.position.row == position.row) return cell;
    }
    return null;
}

fn uiTestCellPixel(
    self: *const App,
    pixels: []const u8,
    position: render.OverlayPosition,
) render.Rgba {
    const rect = render.cellRect(
        @intCast(position.col),
        @intCast(position.row),
        self.fonts.metrics().cell,
    );
    return pixelAt(
        pixels,
        self.size,
        @intFromFloat(rect.x + rect.width / 2),
        @intFromFloat(rect.y + rect.height / 2),
    );
}

fn uiTestCellRect(self: *const App, position: render.OverlayPosition) render.PixelRect {
    return render.cellRect(
        @intCast(position.col),
        @intCast(position.row),
        self.fonts.metrics().cell,
    );
}

/// Fill every cell the UI check will touch with one exact terminal colour and
/// hide the cursor so the idle measurement has no timer behind it.
fn prepareUiTestTerminal(self: *App) !void {
    const terminal = self.activeLive().terminal();
    terminal.feed("\x1b[0m\x1b[2J\x1b[?25l\x1b[48;2;17;31;47m");
    var spaces: [ui_test_min_cols]u8 = undefined;
    @memset(spaces[0..], ' ');
    var row: u32 = 0;
    while (row < ui_test_min_rows) : (row += 1) {
        var control: [32]u8 = undefined;
        const move = try std.fmt.bufPrint(&control, "\x1b[{d};1H", .{row + 1});
        terminal.feed(move);
        terminal.feed(spaces[0..]);
    }
    var parked_control: [32]u8 = undefined;
    const parked = try std.fmt.bufPrint(&parked_control, "\x1b[0m\x1b[{d};{d}H", .{
        ui_test_initial_origin.y + 7 + 1,
        ui_test_initial_origin.x + 10 + 1,
    });
    terminal.feed(parked);
}

const DriverTestContext = struct {
    const FailureKind = enum { none, connect, exchange, rpc_error, expectation };

    endpoint: []const u8,
    window: *const platform.Window,
    failures: usize = 0,
    exchanges: usize = 0,
    failure_kind: FailureKind = .none,
    last_response_len: usize = 0,
    exchange_error: []const u8 = "",
    done: std.atomic.Value(bool) = .init(false),

    fn request(self: *DriverTestContext, client: *platform.DriverClient, frame: []const u8, expected: []const u8) bool {
        const response = client.exchange(std.heap.page_allocator, frame) catch |err| {
            self.failures += 1;
            self.failure_kind = .exchange;
            self.exchange_error = @errorName(err);
            return false;
        };
        defer std.heap.page_allocator.free(response);
        self.exchanges += 1;
        self.last_response_len = response.len;
        if (std.mem.indexOf(u8, response, expected) == null) {
            self.failures += 1;
            self.failure_kind = if (std.mem.indexOf(u8, response, "\"error\":") != null)
                .rpc_error
            else
                .expectation;
            return false;
        }
        return true;
    }

    fn run(self: *DriverTestContext) void {
        defer self.done.store(true, .release);
        defer self.window.postCloseRequest() catch {};
        var client = platform.DriverClient.connect(self.endpoint) catch {
            self.failures += 1;
            self.failure_kind = .connect;
            return;
        };
        defer client.deinit();

        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"inspect\",\"params\":{}}", "\"id\":\"ui-test.action\"")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"click\",\"params\":{\"id\":\"ui-test.action\"}}", "\"id\":2,\"result\":{}")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"ui-test.action\",\"state\":\"focused\",\"equals\":true}},\"timeout_ms\":1000}}", "\"id\":3,\"result\":{}")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"click\",\"params\":{\"id\":\"ui-test.input\"}}", "\"id\":4,\"result\":{}")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"key\",\"params\":{\"chord\":\"CTRL+a\"}}", "\"id\":5,\"result\":{}")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"type\",\"params\":{\"text\":\"driver text\"}}", "\"id\":6,\"result\":{}")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"terminal_text\",\"params\":{\"target\":\"active\"}}", "driver-terminal")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"wait_for\",\"params\":{\"condition\":{\"terminal_text\":{\"target\":\"active\",\"contains\":\"driver-terminal\"}},\"timeout_ms\":1000}}", "\"id\":8,\"result\":{}")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"wait_for\",\"params\":{\"condition\":{\"element\":{\"id\":\"driver-test.missing\",\"state\":\"exists\",\"equals\":true}},\"timeout_ms\":10}}", "\"code\":-32008")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"get_logs\",\"params\":{\"max_bytes\":4096}}", "\"text\":")) return;
        if (!self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"screenshot\",\"params\":{}}", "screenshot-0001.png")) return;
        _ = self.request(&client, "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"quit\",\"params\":{}}", "\"id\":12,\"result\":{}");
    }
};

fn driverTest(self: *App, io: Io, out: *Writer, endpoint: []const u8) !u8 {
    var failures: usize = 0;
    const grid_size = self.activeLive().terminal().gridSize();
    var fixture = try UiTestFixture.init(self.allocator, grid_size);
    defer fixture.deinit();
    self.ui_test = &fixture;
    defer self.ui_test = null;

    try prepareUiTestTerminal(self);
    self.activeLive().terminal().feed("\x1b[1;1Hdriver-terminal");
    try self.moveUiTest(ui_test_initial_origin);
    try self.drawFrame();

    var context = DriverTestContext{ .endpoint = endpoint, .window = self.window };
    const thread = try std.Thread.spawn(.{}, DriverTestContext.run, .{&context});
    try self.run(io, runDeadline(io, 10_000));
    if (!context.done.load(.acquire)) {
        if (self.driver) |driver| driver.stop();
    }
    thread.join();

    failures += reportCheck(out, context.failures == 0 and context.exchanges == 12, "driver-test: {d}/12 JSON-RPC exchanges completed with {d} failure(s), kind {s}, error {s}, last response {d} byte(s)", .{ context.exchanges, context.failures, @tagName(context.failure_kind), context.exchange_error, context.last_response_len });
    failures += reportCheck(out, fixture.dispatch_count == 1 and
        fixture.last_dispatch != null and
        std.mem.eql(u8, fixture.last_dispatch.?.action, ui_test_activate_action), "driver-test: click(id) dispatched the registered action once through SDL and the input router", .{});
    failures += reportCheck(out, std.mem.eql(u8, fixture.field.text(), "driver text"), "driver-test: key and type reached the focused Input through physical-key and committed-text paths", .{});
    failures += reportCheck(out, self.driver_quit_deadline_ns != null, "driver-test: quit returned a response and requested orderly loop shutdown", .{});

    const artifact_dir = self.driver_artifact_dir orelse return error.DriverArtifactDirectoryMissing;
    const screenshot_path = try std.fmt.allocPrint(self.allocator, "{s}{c}screenshot-0001.png", .{
        artifact_dir,
        std.fs.path.sep,
    });
    defer self.allocator.free(screenshot_path);
    const png = Dir.cwd().readFileAlloc(io, screenshot_path, self.allocator, .limited(64 * 1024 * 1024)) catch |err| {
        out.print("driver-test: screenshot read failed: {s}\n", .{@errorName(err)}) catch {};
        failures += 1;
        return if (failures == 0) 0 else 1;
    };
    defer self.allocator.free(png);
    const png_size: ?render.Size = if (png.len >= 24 and std.mem.eql(u8, png[0..8], "\x89PNG\r\n\x1a\n")) .{
        .width = std.mem.readInt(u32, png[16..20], .big),
        .height = std.mem.readInt(u32, png[20..24], .big),
    } else null;
    failures += reportCheck(out, png_size != null and std.meta.eql(png_size.?, self.size), "driver-test: screenshot is a complete {d}x{d} RGBA PNG in the run artifact directory", .{ self.size.width, self.size.height });

    out.print("driver-test: endpoint stayed local, {d} exchange(s), field '{s}', artifact {s}\n", .{
        context.exchanges,
        fixture.field.text(),
        screenshot_path,
    }) catch {};
    return if (failures == 0) 0 else 1;
}

/// The TASK-18/19 integration check. Every rendered cell originates in one
/// semantic Tree element retaining one of the four UI primitives, is projected
/// through Canvas, and reaches the existing renderer on the shared surface.
fn uiTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;

    failures += reportCheck(
        out,
        try waitForScratchpad(self, io, out, .prompt),
        "ui-test: the deterministic hidden scratchpad settled before idle measurement",
        .{},
    );
    try settle(self, out);
    const grid_size = self.activeLive().terminal().gridSize();
    const fixed_setup = self.window.state.logical.width == ui_test_width and
        self.window.state.logical.height == ui_test_height and
        !self.window.isVisible() and !self.scheduler.force and self.family.len == 0 and
        self.activeLive().child() == null;
    failures += reportCheck(out, fixed_setup, "ui-test: fixed hidden {d}x{d}, bundled font request, no child, force redraw off; got {d}x{d}, visible {}, family '{s}', child {}, force {}", .{
        ui_test_width,
        ui_test_height,
        self.window.state.logical.width,
        self.window.state.logical.height,
        self.window.isVisible(),
        self.family,
        self.activeLive().child() != null,
        self.scheduler.force,
    });
    const grid_fits = @as(u32, grid_size.cols) >= ui_test_min_cols and
        @as(u32, grid_size.rows) >= ui_test_min_rows;
    failures += reportCheck(out, grid_fits, "ui-test: grid {d}x{d} contains the {d}x{d} fixture", .{
        grid_size.cols,
        grid_size.rows,
        ui_test_min_cols,
        ui_test_min_rows,
    });
    if (!grid_fits) return 1;

    try prepareUiTestTerminal(self);
    var fixture = try UiTestFixture.init(self.allocator, grid_size);
    defer fixture.deinit();
    self.ui_test = &fixture;
    defer self.ui_test = null;

    const registered_actions = self.actions.definitions();
    failures += reportCheck(out, registered_actions.len == 49 and
        std.mem.eql(u8, registered_actions[0].name, clipboard_copy_action) and
        std.mem.eql(u8, registered_actions[1].name, clipboard_paste_action) and
        std.mem.eql(u8, registered_actions[2].name, sidebar_toggle_action) and
        std.mem.eql(u8, registered_actions[3].name, sidebar_narrow_action) and
        std.mem.eql(u8, registered_actions[4].name, sidebar_widen_action) and
        std.mem.eql(u8, registered_actions[5].name, sidebar_focus_action) and
        std.mem.eql(u8, registered_actions[6].name, workspace_activate_action) and
        std.mem.eql(u8, registered_actions[7].name, workspace_create_action) and
        std.mem.eql(u8, registered_actions[8].name, workspace_rename_action) and
        std.mem.eql(u8, registered_actions[9].name, workspace_switch_action) and
        std.mem.eql(u8, registered_actions[10].name, workspace_close_action) and
        std.mem.eql(u8, registered_actions[11].name, workspace_close_confirm_action) and
        std.mem.eql(u8, registered_actions[12].name, workspace_close_cancel_action) and
        std.mem.eql(u8, registered_actions[13].name, tab_activate_action) and
        std.mem.eql(u8, registered_actions[14].name, tab_new_action) and
        std.mem.eql(u8, registered_actions[15].name, tab_close_action) and
        std.mem.eql(u8, registered_actions[16].name, tab_close_confirm_action) and
        std.mem.eql(u8, registered_actions[17].name, tab_close_cancel_action) and
        std.mem.eql(u8, registered_actions[18].name, tab_rename_action) and
        std.mem.eql(u8, registered_actions[19].name, tab_rename_commit_action) and
        std.mem.eql(u8, registered_actions[20].name, tab_rename_cancel_action) and
        std.mem.eql(u8, registered_actions[21].name, tab_previous_action) and
        std.mem.eql(u8, registered_actions[22].name, tab_next_action) and
        std.mem.eql(u8, registered_actions[23].name, tab_goto_action) and
        std.mem.eql(u8, registered_actions[24].name, tab_move_action) and
        std.mem.eql(u8, registered_actions[25].name, tab_reorder_action) and
        std.mem.eql(u8, registered_actions[26].name, sidebar_resize_action) and
        std.mem.eql(u8, registered_actions[27].name, pane_activate_action) and
        std.mem.eql(u8, registered_actions[28].name, pane_split_action) and
        std.mem.eql(u8, registered_actions[29].name, pane_focus_action) and
        std.mem.eql(u8, registered_actions[30].name, pane_resize_action) and
        std.mem.eql(u8, registered_actions[31].name, pane_zoom_action) and
        std.mem.eql(u8, registered_actions[32].name, pane_close_action) and
        std.mem.eql(u8, registered_actions[33].name, scratchpad_toggle_50_action) and
        std.mem.eql(u8, registered_actions[34].name, scratchpad_toggle_90_action) and
        std.mem.eql(u8, registered_actions[35].name, scratchpad_restart_action) and
        std.mem.eql(u8, registered_actions[36].name, scratchpad_hide_action) and
        std.mem.eql(u8, registered_actions[37].name, palette_open_action) and
        std.mem.eql(u8, registered_actions[38].name, palette_activate_action) and
        std.mem.eql(u8, registered_actions[39].name, terminal_open_link_action) and
        std.mem.eql(u8, registered_actions[40].name, search_open_action) and
        std.mem.eql(u8, registered_actions[41].name, search_close_action) and
        std.mem.eql(u8, registered_actions[42].name, search_next_action) and
        std.mem.eql(u8, registered_actions[43].name, search_previous_action) and
        std.mem.eql(u8, registered_actions[44].name, search_case_action) and
        std.mem.eql(u8, registered_actions[45].name, search_regex_action) and
        std.mem.eql(u8, registered_actions[46].name, search_activate_match_action) and
        std.mem.eql(u8, registered_actions[47].name, terminal_context_menu_action) and
        std.mem.eql(u8, registered_actions[48].name, ui_test_activate_action), "ui-test: registry enumeration exposes clipboard, sidebar, workspace, tab, pane, scratchpad, palette, link, search, context-menu and fixture actions in stable order", .{});

    try self.moveUiTest(ui_test_initial_origin);
    try self.drawFrame();

    const expected_ids = [_][]const u8{
        "ui-test.surface",
        "ui-test.styled",
        "ui-test.action",
        "ui-test.input",
        "ui-test.overlap",
        "ui-test.transparent",
    };
    const elements = fixture.tree.elements();
    var ids_match = elements.len == expected_ids.len;
    if (ids_match) {
        for (elements, expected_ids) |element, expected| {
            if (!std.mem.eql(u8, element.id.value, expected)) {
                ids_match = false;
                break;
            }
        }
    }
    const action_element = fixture.tree.byId(.{ .value = "ui-test.action" });
    const input_element = fixture.tree.byId(.{ .value = "ui-test.input" });
    var actions = fixture.tree.byRole("action");
    const action_by_role = actions.next();
    failures += reportCheck(out, ids_match and action_element != null and input_element != null and
        action_by_role != null and std.mem.eql(u8, action_by_role.?.id.value, "ui-test.action") and
        actions.next() == null and std.mem.eql(u8, action_element.?.role, "action") and
        std.mem.eql(u8, input_element.?.role, "input") and
        action_element.?.parent != null and
        std.mem.eql(u8, action_element.?.parent.?.value, "ui-test.surface") and
        !action_element.?.bounds.isEmpty(), "ui-test: semantic queries return six stable ids, action/input roles and pixel bounds", .{});

    var initial_json_buffer: [4096]u8 = undefined;
    var initial_json_writer = std.Io.Writer.fixed(&initial_json_buffer);
    try fixture.tree.writeJson(&initial_json_writer);
    const initial_json = initial_json_writer.buffered();
    var repeated_json_buffer: [4096]u8 = undefined;
    var repeated_json_writer = std.Io.Writer.fixed(&repeated_json_buffer);
    try fixture.tree.writeJson(&repeated_json_writer);
    const repeated_json = repeated_json_writer.buffered();
    failures += reportCheck(out, std.mem.eql(u8, initial_json, repeated_json) and
        std.mem.indexOf(u8, initial_json, "\"id\":\"ui-test.action\"") != null and
        std.mem.indexOf(u8, initial_json, "\"role\":\"action\"") != null and
        std.mem.indexOf(u8, initial_json, "\"bounds\":{") != null, "ui-test: semantic JSON is deterministic and includes ids, roles and bounds", .{});
    out.print("ui-test: semantic {s}\n", .{initial_json}) catch {};
    const initial_action_bounds = action_element.?.bounds;

    const blue = ui.resolveRole(&default_palette, .blue);
    const red = ui.resolveRole(&default_palette, .red);
    const bright_white = ui.resolveRole(&default_palette, .bright_white);
    const bright_yellow = ui.resolveRole(&default_palette, .bright_yellow);
    const black = ui.resolveRole(&default_palette, .black);
    const selection = ui.resolveRole(&default_palette, .selection);
    const accent = ui.resolveRole(&default_palette, .accent);

    const initial_view = fixture.view();
    const base_position = fixture.baseSample();
    const overlap_position = fixture.overlapSample();
    const border_position = render.OverlayPosition{
        .col = fixture.surfaceRect().x,
        .row = fixture.surfaceRect().y,
    };
    const title_position = render.OverlayPosition{
        .col = fixture.surfaceRect().x + 3,
        .row = fixture.surfaceRect().y,
    };
    const text_position = render.OverlayPosition{
        .col = fixture.textRect().x,
        .row = fixture.textRect().y,
    };
    const interactive_position = render.OverlayPosition{
        .col = fixture.interactiveRect().x,
        .row = fixture.interactiveRect().y,
    };
    const input_position = render.OverlayPosition{
        .col = fixture.inputRect().x,
        .row = fixture.inputRect().y,
    };
    const transparent_position = fixture.transparentPosition();

    const base_cell = overlayCellAt(initial_view, base_position);
    failures += reportCheck(out, base_cell != null and base_cell.?.text.len == 0 and
        base_cell.?.background != null and sameColor(base_cell.?.background.?, blue), "ui-test: Surface resolves its empty fill cell to theme blue", .{});
    const border_cell = overlayCellAt(initial_view, border_position);
    failures += reportCheck(out, border_cell != null and
        std.mem.eql(u8, border_cell.?.text, "┌") and
        border_cell.?.background != null and sameColor(border_cell.?.background.?, blue), "ui-test: Surface contributes a box-drawing border over its fill", .{});
    const title_cell = overlayCellAt(initial_view, title_position);
    failures += reportCheck(out, title_cell != null and
        std.mem.eql(u8, title_cell.?.text, "U") and title_cell.?.face_style == .bold and
        sameColor(title_cell.?.foreground, bright_yellow), "ui-test: Surface title is painted into its border", .{});
    const text_cell = overlayCellAt(initial_view, text_position);
    failures += reportCheck(out, text_cell != null and
        std.mem.eql(u8, text_cell.?.text, "S") and
        text_cell.?.face_style == .bold_italic and
        sameColor(text_cell.?.foreground, bright_white) and
        text_cell.?.background != null and sameColor(text_cell.?.background.?, blue), "ui-test: Text keeps bold-italic, foreground and underlying Surface fill", .{});
    const interactive_cell = overlayCellAt(initial_view, interactive_position);
    failures += reportCheck(out, interactive_cell != null and
        std.mem.eql(u8, interactive_cell.?.text, "A") and
        interactive_cell.?.face_style == .regular and
        sameColor(interactive_cell.?.foreground, bright_white) and
        interactive_cell.?.underline == null, "ui-test: InteractiveText starts in its normal visual state", .{});
    const input_cell = overlayCellAt(initial_view, input_position);
    failures += reportCheck(out, input_cell != null and
        std.mem.eql(u8, input_cell.?.text, "s") and input_cell.?.background != null and
        sameColor(input_cell.?.background.?, selection), "ui-test: Input paints its selection before focus", .{});
    const overlap_cell = overlayCellAt(initial_view, overlap_position);
    failures += reportCheck(out, overlap_cell != null and overlap_cell.?.text.len == 0 and
        overlap_cell.?.background != null and sameColor(overlap_cell.?.background.?, red), "ui-test: the later overlapping Surface wins painter order", .{});
    const transparent_cell = overlayCellAt(initial_view, transparent_position);
    failures += reportCheck(out, transparent_cell != null and
        std.mem.eql(u8, transparent_cell.?.text, " ") and transparent_cell.?.background == null, "ui-test: transparent Text projects no background", .{});

    const initial_pixels = try self.capture();
    failures += reportCheck(out, sameColor(uiTestCellPixel(self, initial_pixels, base_position), blue), "ui-test: Surface fill reached the shared GPU surface", .{});
    failures += reportCheck(out, sameColor(uiTestCellPixel(self, initial_pixels, overlap_position), red), "ui-test: later-layer red is the captured overlap pixel", .{});
    failures += reportCheck(out, sameColor(uiTestCellPixel(self, initial_pixels, transparent_position), ui_test_terminal_background), "ui-test: terminal RGB shows through the transparent UI cell", .{});
    failures += reportCheck(out, countOther(initial_pixels, self.size, uiTestCellRect(self, border_position), blue) > 0, "ui-test: Surface border has terminal-font glyph ink", .{});
    failures += reportCheck(out, countOther(initial_pixels, self.size, uiTestCellRect(self, text_position), blue) > 0, "ui-test: Text has terminal-font glyph ink", .{});
    failures += reportCheck(out, countOther(initial_pixels, self.size, uiTestCellRect(self, interactive_position), blue) > 0, "ui-test: InteractiveText has glyph or underline ink", .{});
    failures += reportCheck(out, countOther(initial_pixels, self.size, uiTestCellRect(self, input_position), selection) > 0, "ui-test: Input has glyph ink over its selection", .{});

    const before_hover = try self.allocator.dupe(u8, initial_pixels);
    defer self.allocator.free(before_hover);
    const action_point = cellPosition(self, @intCast(fixture.interactiveRect().x), @intCast(fixture.interactiveRect().y));
    const hover_delivered = try postMotion(self, io, out, .{ .x = action_point.x, .y = action_point.y });
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const hover_pixels = try self.capture();
    const hovered_element = fixture.tree.byId(.{ .value = "ui-test.action" });
    const hover_cell = overlayCellAt(fixture.view(), interactive_position);
    failures += reportCheck(out, hover_delivered and hovered_element != null and
        hovered_element.?.state.hovered and hover_cell != null and
        hover_cell.?.face_style == .italic and
        sameColor(hover_cell.?.foreground, bright_yellow) and
        hover_cell.?.underline != null and sameColor(hover_cell.?.underline.?, accent) and
        countDifferingPixelsInRect(before_hover, hover_pixels, self.size, uiTestCellRect(self, interactive_position)) > 0, "ui-test: real pointer motion updates semantic hover and framebuffer highlight", .{});

    const dispatches_before_click = fixture.dispatch_count;
    const click_pressed = try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = action_point.x,
        .y = action_point.y,
    });
    const click_released = try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = action_point.x,
        .y = action_point.y,
    });
    const clicked = fixture.last_dispatch;
    failures += reportCheck(out, click_pressed and click_released and
        fixture.dispatch_count == dispatches_before_click + 1 and clicked != null and
        clicked.?.source == .mouse and clicked.?.origin != null and
        std.mem.eql(u8, clicked.?.origin.?.value, "ui-test.action") and
        std.mem.eql(u8, clicked.?.action, ui_test_activate_action), "ui-test: real left click invokes the registered handler with mouse source and exact origin/action", .{});

    const dispatches_before_enter = fixture.dispatch_count;
    const enter_delivered = try postKey(self, io, out, '\r', .{});
    const entered = fixture.last_dispatch;
    failures += reportCheck(out, enter_delivered and
        fixture.dispatch_count == dispatches_before_enter + 1 and entered != null and clicked != null and
        entered.?.source == .keybinding and
        std.mem.eql(u8, entered.?.origin.?.value, clicked.?.origin.?.value) and
        std.mem.eql(u8, entered.?.action, clicked.?.action), "ui-test: Enter dispatches the same registered action/origin as click with keybinding source", .{});

    const tab_to_input = try postKey(self, io, out, '\t', .{});
    const input_focused = fixture.tree.byId(.{ .value = "ui-test.input" });
    failures += reportCheck(out, tab_to_input and input_focused != null and
        input_focused.?.state.focused, "ui-test: Tab reaches the interactive Input", .{});
    const shift_tab_to_action = try postKey(self, io, out, '\t', .{ .shift = true });
    const action_focused_back = fixture.tree.byId(.{ .value = "ui-test.action" });
    failures += reportCheck(out, shift_tab_to_action and action_focused_back != null and
        action_focused_back.?.state.focused, "ui-test: Shift+Tab reaches the interactive action", .{});

    _ = try postKey(self, io, out, '\t', .{});
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const before_key = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(before_key);
    const key_delivered = try postKey(self, io, out, 'k', .{});
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const after_key = try self.capture();
    const typed_position = render.OverlayPosition{
        .col = fixture.inputRect().x,
        .row = fixture.inputRect().y,
    };
    const typed_cursor_position = render.OverlayPosition{
        .col = fixture.inputRect().x + 1,
        .row = fixture.inputRect().y,
    };
    const typed_view = fixture.view();
    const typed_cell = overlayCellAt(typed_view, typed_position);
    const typed_cursor_cell = overlayCellAt(typed_view, typed_cursor_position);
    failures += reportCheck(out, key_delivered and std.mem.eql(u8, fixture.field.text(), "k") and
        typed_cell != null and std.mem.eql(u8, typed_cell.?.text, "k") and
        typed_cell.?.background != null and sameColor(typed_cell.?.background.?, black) and
        typed_cursor_cell != null and typed_cursor_cell.?.background != null and
        sameColor(typed_cursor_cell.?.background.?, accent), "ui-test: focused Input typed through the SDL key path", .{});
    failures += reportCheck(out, countDifferingPixels(before_key, after_key) > 0 and
        countOther(after_key, self.size, uiTestCellRect(self, typed_position), black) > 0, "ui-test: typed input changed pixels and the new glyph has ink", .{});

    const input_command: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true },
    };
    _ = try postKey(self, io, out, 'a', input_command);
    const action_dispatches_before_input_copy = self.action_dispatch_count;
    _ = try postKey(self, io, out, 'c', input_command);
    const copied_input = try clipboardNow(self);
    defer self.allocator.free(copied_input);
    failures += reportCheck(out, std.mem.eql(u8, copied_input, "k") and
        self.action_dispatch_count == action_dispatches_before_input_copy + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", clipboard_copy_action), "ui-test: native copy targets the focused Input through the production registry route", .{});

    try platform.setClipboardText(self.allocator, "bad\x01");
    const action_dispatches_before_invalid_paste = self.action_dispatch_count;
    const invalid_paste_delivered = try postKey(self, io, out, 'v', input_command);
    failures += reportCheck(out, invalid_paste_delivered and
        std.mem.eql(u8, fixture.field.text(), "k") and
        self.action_dispatch_count == action_dispatches_before_invalid_paste + 1, "ui-test: rejected control-bearing clipboard paste is atomic and the app continues", .{});

    try platform.setClipboardText(self.allocator, "one\r\n\ttwo");
    const action_dispatches_before_input_paste = self.action_dispatch_count;
    const valid_paste_delivered = try postKey(self, io, out, 'v', input_command);
    failures += reportCheck(out, valid_paste_delivered and
        std.mem.eql(u8, fixture.field.text(), "one two") and
        self.action_dispatch_count == action_dispatches_before_input_paste + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", clipboard_paste_action), "ui-test: a valid paste after rejection normalizes a CR/LF/tab run to one space", .{});

    const terminal_routes_before_modifiers = self.terminal_key_route_count;
    var modified_keys_delivered = true;
    for ([_]platform.Mods{ .{ .ctrl = true }, .{ .alt = true }, .{ .super = true } }) |mods| {
        const modified_press = try postKeyAction(self, io, out, 'x', mods, .press);
        const changed_release = try postKeyAction(self, io, out, 'x', .{}, .release);
        modified_keys_delivered = modified_keys_delivered and modified_press and changed_release;
    }
    failures += reportCheck(out, modified_keys_delivered and
        std.mem.eql(u8, fixture.field.text(), "one two") and
        self.terminal_key_route_count == terminal_routes_before_modifiers + 6 and
        self.ui_key_state.len == 0, "ui-test: Ctrl/Alt/Super+X do not edit Input, and modifier-changed releases remain terminal-owned", .{});
    self.child_input.len = 0;

    const terminal_routes_before_owned = self.terminal_key_route_count;
    const owned_press = try postKeyAction(self, io, out, 'y', .{ .shift = true }, .press);
    const owned_release = try postKeyAction(self, io, out, 'y', .{}, .release);
    failures += reportCheck(out, owned_press and owned_release and
        std.mem.eql(u8, fixture.field.text(), "one twoy") and
        self.terminal_key_route_count == terminal_routes_before_owned and
        self.ui_key_state.len == 0, "ui-test: an Input-owned press keeps its release after Shift is released first", .{});

    const duplicate_press = try postKeyAction(self, io, out, 'd', .{}, .press);
    const duplicate_press_again = try postKeyAction(self, io, out, 'd', .{}, .press);
    const duplicate_release = try postKeyAction(self, io, out, 'd', .{}, .release);
    failures += reportCheck(out, duplicate_press and duplicate_press_again and duplicate_release and
        std.mem.eql(u8, fixture.field.text(), "one twoyd"), "ui-test: a duplicate owned press is consumed without a duplicate Input edit", .{});

    const repeat_press = try postKeyAction(self, io, out, 'r', .{}, .press);
    const repeat_event = try postKeyAction(self, io, out, 'r', .{}, .repeat);
    const repeat_release = try postKeyAction(self, io, out, 'r', .{}, .release);
    failures += reportCheck(out, repeat_press and repeat_event and repeat_release and
        std.mem.eql(u8, fixture.field.text(), "one twoydrr"), "ui-test: an owned printable repeat edits Input while its release stays consumed", .{});

    const terminal_routes_before_tab = self.terminal_key_route_count;
    const tab_press = try postKeyAction(self, io, out, '\t', .{}, .press);
    const tab_owned = self.ui_key_state.len == 1;
    const tab_release = try postKeyAction(self, io, out, '\t', .{ .ctrl = true }, .release);
    const action_after_tab = fixture.tree.byId(.{ .value = "ui-test.action" });
    failures += reportCheck(out, tab_press and tab_owned and tab_release and
        self.ui_key_state.len == 0 and
        self.terminal_key_route_count == terminal_routes_before_tab and
        action_after_tab != null and action_after_tab.?.state.focused, "ui-test: Tab release remains UI-owned after focus and modifiers change", .{});

    const ui_dispatches_before_owned_enter = fixture.dispatch_count;
    const terminal_routes_before_enter_release = self.terminal_key_route_count;
    const enter_press = try postKeyAction(self, io, out, '\r', .{}, .press);
    const enter_duplicate = try postKeyAction(self, io, out, '\r', .{}, .press);
    const enter_release = try postKeyAction(self, io, out, '\r', .{ .alt = true }, .release);
    failures += reportCheck(out, enter_press and enter_duplicate and enter_release and
        fixture.dispatch_count == ui_dispatches_before_owned_enter + 1 and
        self.ui_key_state.len == 0 and
        self.terminal_key_route_count == terminal_routes_before_enter_release, "ui-test: Enter dispatches once and its modifier-changed release remains UI-owned", .{});

    const action_focused_before_move = fixture.tree.byId(.{ .value = "ui-test.action" });
    failures += reportCheck(out, action_focused_before_move != null and
        action_focused_before_move.?.state.focused, "ui-test: action is focused before stable-id rebuild", .{});

    const old_base_position = base_position;
    try self.moveUiTest(ui_test_moved_origin);
    try self.drawFrame();
    const moved_pixels = try self.capture();
    failures += reportCheck(out, sameColor(uiTestCellPixel(self, moved_pixels, old_base_position), ui_test_terminal_background), "ui-test: moving the overlay restores the old terminal pixel", .{});
    failures += reportCheck(out, sameColor(uiTestCellPixel(self, moved_pixels, fixture.baseSample()), blue), "ui-test: moving the overlay paints the new Surface position", .{});
    const moved_action = fixture.tree.byId(.{ .value = "ui-test.action" });
    var moved_json_buffer: [4096]u8 = undefined;
    var moved_json_writer = std.Io.Writer.fixed(&moved_json_buffer);
    try fixture.tree.writeJson(&moved_json_writer);
    const moved_json = moved_json_writer.buffered();
    var moved_bounds_in_json = false;
    if (moved_action) |element| {
        var bounds_buffer: [160]u8 = undefined;
        var bounds_writer = std.Io.Writer.fixed(&bounds_buffer);
        try bounds_writer.print("\"bounds\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}}}", .{
            element.bounds.x,
            element.bounds.y,
            element.bounds.width,
            element.bounds.height,
        });
        moved_bounds_in_json = std.mem.indexOf(u8, moved_json, bounds_writer.buffered()) != null;
    }
    failures += reportCheck(out, moved_action != null and moved_action.?.state.focused and
        !std.meta.eql(moved_action.?.bounds, initial_action_bounds) and
        std.mem.eql(u8, moved_action.?.id.value, "ui-test.action") and
        !std.mem.eql(u8, moved_json, initial_json) and
        moved_bounds_in_json and
        std.mem.indexOf(u8, moved_json, "\"id\":\"ui-test.action\"") != null, "ui-test: stable action id/focus survive movement while bounds and JSON reflect the new position", .{});
    out.print("ui-test: moved semantic {s}\n", .{moved_json}) catch {};

    const dispatches_before_elsewhere = fixture.dispatch_count;
    const elsewhere = cellPosition(self, 0, 0);
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = elsewhere.x,
        .y = elsewhere.y,
    });
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = elsewhere.x,
        .y = elsewhere.y,
    });
    failures += reportCheck(out, fixture.dispatch_count == dispatches_before_elsewhere, "ui-test: press and release away from interactive elements do not dispatch", .{});

    const moved_base_position = fixture.baseSample();
    try self.removeUiTest();
    try self.drawFrame();
    const removed_view = fixture.view();
    const removed_pixels = try self.capture();
    failures += reportCheck(out, removed_view.cells.len == 0 and
        sameColor(uiTestCellPixel(self, removed_pixels, moved_base_position), ui_test_terminal_background), "ui-test: an empty overlay removes its pixels and restores the terminal", .{});

    try self.moveUiTest(ui_test_initial_origin);
    try self.drawFrame();

    const damaged_position = fixture.baseSample();
    self.activeLive().terminal().feed("\x1b[48;2;41;73;59m \x1b[0m");
    const before_damage = self.focusedGrid().gridStats();
    const before_overlay_damage = self.overlay_grid.gridStats();
    try self.drawFrame();
    const damage_delta = statDelta(self.focusedGrid().gridStats(), before_damage);
    const overlay_damage_delta = statDelta(self.overlay_grid.gridStats(), before_overlay_damage);
    const damaged_pixels = try self.capture();
    failures += reportCheck(out, damage_delta.rows == 1 and damage_delta.draws + overlay_damage_delta.draws == 3 and
        damage_delta.buffer_uploads + overlay_damage_delta.buffer_uploads == 3 and
        damage_delta.atlas_uploads + overlay_damage_delta.atlas_uploads == 0 and
        sameColor(uiTestCellPixel(self, damaged_pixels, damaged_position), blue), "ui-test: one terminal row used one base pass plus two overlay passes ({d} rows, {d} draws, {d} buffer uploads, {d} atlas uploads)", .{
        damage_delta.rows,
        damage_delta.draws + overlay_damage_delta.draws,
        damage_delta.buffer_uploads + overlay_damage_delta.buffer_uploads,
        damage_delta.atlas_uploads + overlay_damage_delta.atlas_uploads,
    });

    try self.removeUiTest();
    try self.drawFrame();
    const revealed_damage = try self.capture();
    failures += reportCheck(out, sameColor(uiTestCellPixel(self, revealed_damage, damaged_position), ui_test_terminal_damage), "ui-test: removing that overlay reveals the terminal's changed RGB cell", .{});
    try self.moveUiTest(ui_test_initial_origin);
    try self.drawFrame();

    try settle(self, out);
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const before_idle_pixels = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(before_idle_pixels);
    const before_idle = self.focusedGrid().gridStats();
    try self.drawFrame();
    const idle = statDelta(self.focusedGrid().gridStats(), before_idle);
    const after_idle_pixels = try self.capture();
    failures += reportCheck(out, idle.rows == 0 and idle.draws == 0 and
        idle.buffer_uploads == 0 and idle.atlas_uploads == 0 and idle.skipped_frames == 1, "ui-test: unchanged frame did zero GPU work ({d} rows, {d} draws, {d} buffer, {d} atlas, {d} skipped)", .{
        idle.rows,
        idle.draws,
        idle.buffer_uploads,
        idle.atlas_uploads,
        idle.skipped_frames,
    });
    failures += reportCheck(out, std.mem.eql(u8, before_idle_pixels, after_idle_pixels), "ui-test: unchanged frame left the capture byte-identical", .{});

    const frames_before = self.scheduler.frames;
    const idle_deadline = Io.Clock.real.now(io).nanoseconds + 250 * std.time.ns_per_ms;
    try self.run(io, idle_deadline);
    failures += reportCheck(out, self.scheduler.frames == frames_before, "ui-test: 250 ms idle event loop drew {d} frame(s)", .{self.scheduler.frames - frames_before});

    out.print("ui-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

fn sidebarCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("sidebar-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn elementCenter(element: *const ui.Element, scale: platform.Scale) struct { x: f32, y: f32 } {
    const device_x = @as(f32, @floatFromInt(element.bounds.x)) +
        @as(f32, @floatFromInt(element.bounds.width)) / 2;
    const device_y = @as(f32, @floatFromInt(element.bounds.y)) +
        @as(f32, @floatFromInt(element.bounds.height)) / 2;
    return .{ .x = device_x / scale.factor, .y = device_y / scale.factor };
}

/// Exercise the production workspace/sidebar composition and its real SDL
/// input paths. The second session is provisioned as fixture state because tab
/// creation belongs to TASK-29; every selection, visibility and size change is
/// then performed exactly as a user performs it.
fn sidebarTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    self.activeLive().terminal().feed("\x1b[2J\x1b[HFIRST TAB");

    const terminal_size = self.activeLive().terminal().gridSize();
    const second_session_id = try self.activeWorkspace().createSession(.human_terminal, terminal_size);
    const second = self.activeWorkspace().sessionById(second_session_id) orelse return error.SessionNotFound;
    second.terminal().setClipboardAccess(.{
        .read_fn = readNativeClipboard,
        .write_fn = writeNativeClipboard,
    });
    second.terminal().feed("\x1b[2J\x1b[HSECOND TAB");
    try self.activePresentation().pane_renderers.ensureUnusedCapacity(self.allocator, 1);
    self.activePresentation().pane_renderers.appendAssumeCapacity(try self.newPaneRenderer(second_session_id));
    const second_tab_id = try self.activeWorkspace().registerTab("Terminal 2", second_session_id);
    const second_tab = self.activeWorkspace().tab(second_tab_id) orelse return error.SessionNotFound;
    const command_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };

    try self.drawFrame();
    const initial_origin = self.sidebarOriginColumns();
    const canvas = self.ui_canvas.bounds();
    const workspace_key = self.activePresentation().key;
    var workspace_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const workspace_semantic = try workspaceSemanticId(&workspace_id_buffer, workspace_key);
    var first_tab_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const first_tab_semantic = try tabSemanticId(&first_tab_id_buffer, workspace_key, .first);
    var second_tab_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const second_tab_semantic = try tabSemanticId(&second_tab_id_buffer, workspace_key, second_tab.id());
    const first_element = self.ui_tree.byId(.{ .value = first_tab_semantic });
    const second_element = self.ui_tree.byId(.{ .value = second_tab_semantic });
    const workspace_element = self.ui_tree.byId(.{ .value = workspace_semantic });
    const collapse_element = self.ui_tree.byId(.{ .value = "sidebar.collapse" });
    sidebarCheck(out, &failures, workspace_element != null and first_element != null and
        second_element != null and collapse_element != null, "the production tree lists one workspace, both provisioned tabs and a mouse collapse control", .{});
    sidebarCheck(out, &failures, first_element != null and first_element.?.state.selected and
        second_element != null and !second_element.?.state.selected, "the first tab is the initial semantic selection", .{});
    sidebarCheck(out, &failures, initial_origin != 0 and
        @as(u32, self.activeLive().terminal().gridSize().cols) + initial_origin == canvas.width, "the {d}-column sidebar resizes the terminal to {d} columns", .{
        initial_origin,
        self.activeLive().terminal().gridSize().cols,
    });
    const selected_cell = overlayCellAt(self.overlayView(), .{ .col = 2, .row = 2 });
    const selection_color = ui.resolveRole(&default_palette, .selection);
    sidebarCheck(out, &failures, selected_cell != null and selected_cell.?.background != null and
        sameColor(selected_cell.?.background.?, selection_color), "the selected tab row is painted with the selection colour", .{});
    if (self.focusedGrid().cursor()) |cursor| {
        sidebarCheck(out, &failures, cursor.x >= @as(f32, @floatFromInt(self.terminalOriginPixels())), "the terminal cursor is inset with the terminal surface", .{});
    } else {
        sidebarCheck(out, &failures, false, "the terminal cursor is inset with the terminal surface", .{});
    }

    if (second_element) |element| {
        const point = elementCenter(element, self.window.state.scale);
        sidebarCheck(out, &failures, try postButton(self, io, out, .{
            .button = .left,
            .action = .press,
            .x = point.x,
            .y = point.y,
        }) and try postButton(self, io, out, .{
            .button = .left,
            .action = .release,
            .x = point.x,
            .y = point.y,
        }), "SDL delivered the tab click", .{});
    }
    try self.drawFrame();
    sidebarCheck(out, &failures, self.activePresentation().active_session_id == second_session_id and
        self.activeLive().terminal().visibleTextContains("SECOND TAB"), "clicking Terminal 2 switches the presented session", .{});
    const selected_second = self.ui_tree.byId(.{ .value = second_tab_semantic });
    const deselected_first = self.ui_tree.byId(.{ .value = first_tab_semantic });
    sidebarCheck(out, &failures, selected_second != null and selected_second.?.state.selected and
        deselected_first != null and !deselected_first.?.state.selected, "clicking updates the semantic active selection", .{});

    const focus_clear_point = cellPosition(self, 5, 5);
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = focus_clear_point.x,
        .y = focus_clear_point.y,
    });
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = focus_clear_point.x,
        .y = focus_clear_point.y,
    });
    sidebarCheck(out, &failures, self.ui_tree.focusedElement() == null, "a terminal click clears the mouse-established sidebar focus before keyboard navigation", .{});
    sidebarCheck(out, &failures, try postNamedKey(self, io, out, .down, command_mods), "the explicit sidebar focus binding was delivered through SDL", .{});
    const keyboard_entry_focus = self.ui_tree.focusedElement();
    sidebarCheck(out, &failures, keyboard_entry_focus != null and
        std.mem.eql(u8, keyboard_entry_focus.?.id.value, workspace_semantic), "the keyboard focus action enters the sidebar on the active workspace", .{});
    sidebarCheck(out, &failures, try postNamedKey(self, io, out, .tab, .{}) and
        try postNamedKey(self, io, out, .enter, .{}), "Tab and Enter were delivered through SDL", .{});
    try self.drawFrame();
    const first_tab = self.activeWorkspace().tab(workspace.TabId.fromOrdinal(0)) orelse return error.SessionNotFound;
    sidebarCheck(out, &failures, self.activePresentation().active_session_id == self.activeWorkspace().focusedPaneSessionId(first_tab.id()).? and
        self.activeLive().terminal().visibleTextContains("FIRST TAB"), "keyboard focus and activation switch back to Terminal 1", .{});

    sidebarCheck(out, &failures, try postKey(self, io, out, 'b', command_mods), "the sidebar toggle binding was delivered through SDL", .{});
    sidebarCheck(out, &failures, !self.sidebar_visible and self.sidebarOriginColumns() == 0 and
        self.activeLive().terminal().gridSize().cols == canvas.width, "the keyboard hides the sidebar and returns its columns to the terminal", .{});
    const reveal = self.ui_tree.byId(.{ .value = "sidebar.reveal" });
    sidebarCheck(out, &failures, reveal != null, "the hidden sidebar exposes a semantic mouse reveal", .{});
    if (reveal) |element| {
        const point = elementCenter(element, self.window.state.scale);
        _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = point.x, .y = point.y });
        _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = point.x, .y = point.y });
    }
    sidebarCheck(out, &failures, self.sidebar_visible and self.sidebarOriginColumns() == initial_origin, "clicking the reveal shows the sidebar at its remembered width", .{});

    const before_keyboard_width = self.sidebarOriginColumns();
    sidebarCheck(out, &failures, try postNamedKey(self, io, out, .right, command_mods), "the keyboard resize binding was delivered through SDL", .{});
    const after_keyboard_width = self.sidebarOriginColumns();
    sidebarCheck(out, &failures, after_keyboard_width > before_keyboard_width and
        self.activeLive().terminal().gridSize().cols + after_keyboard_width == canvas.width, "keyboard widening grows the inset and shrinks the terminal", .{});

    const divider = self.ui_tree.byId(.{ .value = "sidebar.divider" });
    if (divider) |element| {
        const start = elementCenter(element, self.window.state.scale);
        const delta = @as(f32, @floatFromInt(self.fonts.metrics().cell.width_px * 4)) /
            self.window.state.scale.factor;
        _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = start.x, .y = start.y });
        _ = try postMotion(self, io, out, .{ .buttons = .{ .left = true }, .x = start.x + delta, .y = start.y });
        _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = start.x + delta, .y = start.y });
    }
    const after_drag_width = self.sidebarOriginColumns();
    sidebarCheck(out, &failures, after_drag_width > after_keyboard_width and
        self.activeLive().terminal().gridSize().cols + after_drag_width == canvas.width, "dragging the semantic divider grows the inset and resizes the terminal", .{});

    const workspace_after = self.ui_tree.byId(.{ .value = workspace_semantic });
    const dispatches_before_workspace = self.action_dispatch_count;
    if (workspace_after) |element| {
        const point = elementCenter(element, self.window.state.scale);
        _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = point.x, .y = point.y });
        _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = point.x, .y = point.y });
    }
    sidebarCheck(out, &failures, self.action_dispatch_count == dispatches_before_workspace + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", workspace_activate_action), "clicking the workspace row dispatches its named switch action", .{});

    const terminal_point = cellPosition(self, 5, 5);
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = terminal_point.x,
        .y = terminal_point.y,
    });
    _ = try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = terminal_point.x,
        .y = terminal_point.y,
    });
    const terminal_routes_before = self.terminal_key_route_count;
    const session_before_terminal_keys = self.activePresentation().active_session_id;
    _ = try postNamedKey(self, io, out, .tab, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    sidebarCheck(out, &failures, self.ui_tree.focusedElement() == null and
        self.activePresentation().active_session_id == session_before_terminal_keys and
        self.terminal_key_route_count == terminal_routes_before + 4, "a terminal click clears sidebar focus so unbound Tab and Enter return to the terminal", .{});

    const collapse_after = self.ui_tree.byId(.{ .value = "sidebar.collapse" });
    if (collapse_after) |element| {
        const point = elementCenter(element, self.window.state.scale);
        _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = point.x, .y = point.y });
        _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = point.x, .y = point.y });
    }
    sidebarCheck(out, &failures, !self.sidebar_visible and self.sidebarOriginColumns() == 0, "clicking the visible collapse control hides the sidebar", .{});
    _ = try postKey(self, io, out, 'b', command_mods);
    sidebarCheck(out, &failures, self.sidebar_visible and self.sidebarOriginColumns() == after_drag_width, "the keyboard shows the mouse-collapsed sidebar at its remembered width", .{});

    try self.drawFrame();
    _ = try self.capture();
    out.print("sidebar-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

/// The deterministic peer behind every tab in `--tabs-test`. It reports a
/// tracked cwd of /tmp while also printing its real spawn cwd, then exposes
/// separate activity and bell phases after two lines of real user input.
const tabs_test_script =
    "stty -echo; " ++
    "printf '\\033]7;file://localhost/tmp\\007\\033]133;A\\007tabs$ \\033]133;B\\007TAB-PWD:%s\\r\\n' \"$PWD\"; " ++
    "IFS= read -r first; printf '\\033]133;C\\007TAB-ACTIVITY\\r\\n'; " ++
    "IFS= read -r second; printf '\\007TAB-BELL\\r\\n'; " ++
    "while IFS= read -r rest; do :; done";

const tabs_test_budget_ms: i64 = 5000;

const TabsWait = union(enum) {
    terminal_text: []const u8,
    cwd: []const u8,
    element: []const u8,
    attention: struct { id: workspace.TabId, value: workspace.TabAttention },
};

fn tabsWaitMet(self: *App, condition: TabsWait) bool {
    return switch (condition) {
        .terminal_text => |text| self.activeLive().terminal().visibleTextContains(text),
        .cwd => |cwd| if (self.activeLive().workingDirectory()) |actual| std.mem.eql(u8, actual, cwd) else false,
        .element => |id| self.ui_tree.byId(.{ .value = id }) != null,
        .attention => |wanted| if (self.activeWorkspace().tab(wanted.id)) |tab|
            tab.attention() == wanted.value
        else
            false,
    };
}

/// Wait with the ordinary event/poll/draw loop; no test sleep substitutes for
/// the child, worker, SDL event, semantic frame or renderer becoming ready.
fn waitForTabs(self: *App, io: Io, out: *Writer, condition: TabsWait) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + tabs_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        if (tabsWaitMet(self, condition)) return true;
        const event = self.window.pump(@min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) return tabsWaitMet(self, condition);
    }
}

fn tabsCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("tabs-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn clickTabsElement(self: *App, io: Io, out: *Writer, id: []const u8) !bool {
    const element = self.ui_tree.byId(.{ .value = id }) orelse return false;
    const point = elementCenter(element, self.window.state.scale);
    return try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = point.x,
        .y = point.y,
    }) and try postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = point.x,
        .y = point.y,
    });
}

fn dragTabs(self: *App, io: Io, out: *Writer, from_id: []const u8, to_id: []const u8) !bool {
    const from = self.ui_tree.byId(.{ .value = from_id }) orelse return false;
    const to = self.ui_tree.byId(.{ .value = to_id }) orelse return false;
    const start = elementCenter(from, self.window.state.scale);
    const finish = elementCenter(to, self.window.state.scale);
    return try postButton(self, io, out, .{ .button = .left, .action = .press, .x = start.x, .y = start.y }) and
        try postMotion(self, io, out, .{ .buttons = .{ .left = true }, .x = finish.x, .y = finish.y }) and
        try postButton(self, io, out, .{ .button = .left, .action = .release, .x = finish.x, .y = finish.y });
}

/// Exercise TASK-29 through the same SDL, action, semantic-tree, PTY and
/// renderer paths a person uses.
fn tabsTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    try self.drawFrame();
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .terminal_text = "TAB-PWD:" }), "the first real tab child became ready", .{});
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .cwd = "/tmp" }), "the originating tab reported tracked cwd /tmp", .{});

    const create_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    tabsCheck(out, &failures, try postKey(self, io, out, 't', create_mods), "the new-tab binding travelled through SDL", .{});
    const second_id = self.activeWorkspace().activeTabId() orelse return error.SessionNotFound;
    _ = self.activeWorkspace().tab(second_id) orelse return error.SessionNotFound;
    const workspace_key = self.activePresentation().key;
    var second_semantic_buffer: [workspace_semantic_capacity]u8 = undefined;
    const second_semantic = try tabSemanticId(&second_semantic_buffer, workspace_key, second_id);
    var rename_semantic_buffer: [workspace_semantic_capacity]u8 = undefined;
    const rename_semantic = try tabRenameSemanticId(&rename_semantic_buffer, workspace_key);
    tabsCheck(out, &failures, self.activeWorkspace().tabCount() == 2 and
        try waitForTabs(self, io, out, .{ .element = second_semantic }), "new tab {s} is selected and present in the semantic tree", .{second_semantic});
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .terminal_text = "TAB-PWD:/tmp" }), "the new child really spawned in the originating tab's tracked cwd", .{});

    tabsCheck(out, &failures, try clickTabsElement(self, io, out, "tabs.rename"), "the mouse opened inline rename", .{});
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .element = rename_semantic }) and
        self.ui_tree.focusedElement() != null and
        std.mem.eql(u8, self.ui_tree.focusedElement().?.id.value, rename_semantic), "rename is a focused semantic Input", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    tabsCheck(out, &failures, self.rename_input == null and self.rename_tab_id == null and
        !std.mem.eql(u8, self.activeWorkspace().tab(second_id).?.name(), "build"), "Escape cancelled rename without changing the tab", .{});
    tabsCheck(out, &failures, try postNamedKey(self, io, out, .f2, .{}) and
        try waitForTabs(self, io, out, .{ .element = rename_semantic }), "F2 opened the same inline rename action", .{});
    const native_command: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true },
    };
    _ = try postKey(self, io, out, 'a', native_command);
    try self.window.postTextInput("build");
    tabsCheck(out, &failures, try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms), "typed rename text travelled through SDL", .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    tabsCheck(out, &failures, self.activeWorkspace().tab(second_id) != null and
        std.mem.eql(u8, self.activeWorkspace().tab(second_id).?.name(), "build"), "Enter committed the copied tab name", .{});

    const first_tab = self.activeWorkspace().tabAt(0) orelse return error.SessionNotFound;
    const first_id = first_tab.id();
    var first_semantic_buffer: [workspace_semantic_capacity]u8 = undefined;
    const first_semantic = try tabSemanticId(&first_semantic_buffer, workspace_key, first_id);
    tabsCheck(out, &failures, try clickTabsElement(self, io, out, first_semantic) and
        self.activeWorkspace().activeTabId() == first_id, "click switches to the first tab", .{});
    const next_delivered = switch (self.binding_profile) {
        .macos => try postKey(self, io, out, ']', .{ .shift = true, .super = true }),
        .linux_windows => try postNamedKey(self, io, out, .page_down, .{ .ctrl = true }),
    };
    tabsCheck(out, &failures, next_delivered and self.activeWorkspace().activeTabId() == second_id, "the next-tab binding switches tabs", .{});
    const goto_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .alt = true },
    };
    tabsCheck(out, &failures, try postKey(self, io, out, '1', goto_mods) and
        self.activeWorkspace().activeTabId() == first_id, "goto-1 switches directly", .{});

    tabsCheck(out, &failures, try dragTabs(self, io, out, second_semantic, first_semantic), "a real pointer drag reordered the rows", .{});
    tabsCheck(out, &failures, self.activeWorkspace().tabAt(0).?.id() == second_id, "drag placed the second tab first", .{});
    _ = try self.activateTab(second_id);
    tabsCheck(out, &failures, try postNamedKey(self, io, out, .down, .{ .alt = true, .shift = true }) and
        self.activeWorkspace().tabAt(1).?.id() == second_id, "the tab.move keyboard action restored the order", .{});

    const terminal_point = cellPosition(self, 4, 4);
    _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = terminal_point.x, .y = terminal_point.y });
    _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = terminal_point.x, .y = terminal_point.y });
    try self.window.postTextInput("activity");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    _ = try postKey(self, io, out, '1', goto_mods);
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .attention = .{ .id = second_id, .value = .activity } }), "hidden output marked background activity", .{});
    _ = try self.activateTab(second_id);
    tabsCheck(out, &failures, self.activeWorkspace().tab(second_id).?.attention() == .none, "activation cleared activity", .{});

    _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = terminal_point.x, .y = terminal_point.y });
    _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = terminal_point.x, .y = terminal_point.y });
    try self.window.postTextInput("bell");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    _ = try postKey(self, io, out, '1', goto_mods);
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .attention = .{ .id = second_id, .value = .bell } }), "a hidden BEL upgraded attention to bell", .{});
    _ = try self.activateTab(second_id);

    tabsCheck(out, &failures, try clickTabsElement(self, io, out, "tabs.close") and
        try waitForTabs(self, io, out, .{ .element = "tab-close.dialog" }), "closing a running foreground process opened the semantic confirmation", .{});
    const routes_before_modal = self.terminal_key_route_count;
    const queued_before_modal = self.pending_child_bytes.items.len;
    try self.window.postTextInput("LEAK");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postKey(self, io, out, 'x', .{});
    tabsCheck(out, &failures, self.terminal_key_route_count == routes_before_modal and
        self.pending_child_bytes.items.len == queued_before_modal and self.pending_committed_text.len == 0, "the modal consumed committed and key input instead of leaking it to the terminal", .{});
    const count_before_modal_click = self.activeWorkspace().tabCount();
    _ = try clickTabsElement(self, io, out, "tabs.new");
    tabsCheck(out, &failures, self.activeWorkspace().tabCount() == count_before_modal_click and
        self.pending_close_tab_id == second_id, "the modal consumed a pointer click on controls behind it", .{});
    _ = try postNamedKey(self, io, out, .tab, .{ .shift = true });
    tabsCheck(out, &failures, if (self.ui_tree.focusedElement()) |focused|
        std.mem.eql(u8, focused.id.value, "tab-close.confirm")
    else
        false, "Shift+Tab wraps from cancel to confirm inside the modal", .{});
    _ = try postNamedKey(self, io, out, .tab, .{});
    tabsCheck(out, &failures, if (self.ui_tree.focusedElement()) |focused|
        std.mem.eql(u8, focused.id.value, "tab-close.cancel")
    else
        false, "Tab wraps from confirm to cancel inside the modal", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    tabsCheck(out, &failures, self.pending_close_tab_id == null and self.activeWorkspace().tab(second_id) != null, "Escape cancelled close", .{});

    _ = try clickTabsElement(self, io, out, "tabs.close");
    _ = try postNamedKey(self, io, out, .tab, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    tabsCheck(out, &failures, self.activeWorkspace().tab(second_id) == null and
        self.activeWorkspace().activeTabId() == first_id, "keyboard confirmation closed the tab and selected its neighbour", .{});

    _ = try postKey(self, io, out, 't', create_mods);
    tabsCheck(out, &failures, self.activeWorkspace().tabCount() == 2 and
        try waitForTabs(self, io, out, .{ .terminal_text = "TAB-PWD:/tmp" }), "a final visual-fixture tab started through the real binding", .{});
    _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = terminal_point.x, .y = terminal_point.y });
    _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = terminal_point.x, .y = terminal_point.y });
    try self.window.postTextInput("activity");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    tabsCheck(out, &failures, try waitForTabs(self, io, out, .{ .terminal_text = "TAB-ACTIVITY" }), "the visual-fixture child entered a foreground phase", .{});
    tabsCheck(out, &failures, try clickTabsElement(self, io, out, "tabs.close") and
        try waitForTabs(self, io, out, .{ .element = "tab-close.dialog" }), "closing the foreground tab presents the confirmation for visual capture", .{});

    try self.drawFrame();
    _ = try self.capture();
    out.print("tabs-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

/// The deterministic peer behind every pane in `--panes-test`. OSC 7 supplies
/// the tracked cwd inherited by later splits; the actual spawn cwd and every
/// input line are printed so the test can distinguish model state from a real
/// ExecutionContext spawn and PTY round trip. Mouse reporting is enabled by
/// terminal bytes from the program itself.
const panes_test_script =
    "stty -echo; " ++
    "printf '\\033]7;file://localhost/tmp\\007\\033]133;A\\007pane$ \\033]133;B\\007PANE-PWD:%s\\r\\n\\033[?1006;1000h' \"$PWD\"; " ++
    "while IFS= read -r line; do printf '\\033]133;C\\007PANE-ECHO:%s\\r\\n' \"$line\"; done";

const PanesWait = union(enum) {
    focused_text: []const u8,
    session_text: struct { id: session.SessionId, text: []const u8 },
    cwd: []const u8,
    element: []const u8,
};

fn panesWaitMet(self: *App, condition: PanesWait) !bool {
    return switch (condition) {
        .focused_text => |text| self.activeLive().terminal().visibleTextContains(text),
        .session_text => |wanted| session_text: {
            const live = self.activeWorkspace().sessionById(wanted.id) orelse break :session_text false;
            try live.terminal().refresh(self.allocator);
            break :session_text live.terminal().visibleTextContains(wanted.text);
        },
        .cwd => |cwd| if (self.activeLive().workingDirectory()) |actual| std.mem.eql(u8, actual, cwd) else false,
        .element => |id| self.ui_tree.byId(.{ .value = id }) != null,
    };
}

fn waitForPanes(self: *App, io: Io, out: *Writer, condition: PanesWait) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + tabs_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        if (try panesWaitMet(self, condition)) return true;
        const event = self.window.pump(@min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) return try panesWaitMet(self, condition);
    }
}

fn panesCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("panes-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn workspaceSemanticId(buffer: []u8, key: workspace.WorkspaceKey) ![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}", .{@intFromEnum(key)});
}

fn tabSemanticId(buffer: []u8, key: workspace.WorkspaceKey, tab_id: workspace.TabId) ![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}.tab.{d}", .{ @intFromEnum(key), @intFromEnum(tab_id) });
}

fn tabRenameSemanticId(buffer: []u8, key: workspace.WorkspaceKey) ![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}.tab.rename.input", .{@intFromEnum(key)});
}

fn paneSemanticId(buffer: []u8, key: workspace.WorkspaceKey, pane_id: workspace.PaneId) ![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}.pane.{d}", .{ @intFromEnum(key), @intFromEnum(pane_id) });
}

fn dividerSemanticId(buffer: []u8, key: workspace.WorkspaceKey, divider_id: workspace.DividerId) ![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}.divider.{d}", .{ @intFromEnum(key), @intFromEnum(divider_id) });
}

fn dividerVisualSemanticId(buffer: []u8, key: workspace.WorkspaceKey, divider_id: workspace.DividerId) ![]const u8 {
    return std.fmt.bufPrint(buffer, "workspace.{d}.divider.visual.{d}", .{ @intFromEnum(key), @intFromEnum(divider_id) });
}

fn scratchpadSemanticId(buffer: []u8, key: workspace.WorkspaceKey, suffix: []const u8) ![]const u8 {
    return if (suffix.len == 0)
        std.fmt.bufPrint(buffer, "workspace.{d}.scratchpad", .{@intFromEnum(key)})
    else
        std.fmt.bufPrint(buffer, "workspace.{d}.scratchpad.{s}", .{ @intFromEnum(key), suffix });
}

fn dragPaneDivider(
    self: *App,
    io: Io,
    out: *Writer,
    divider: workspace.DividerLayout,
    cells: i32,
) !bool {
    var id_buffer: [pane_semantic_capacity]u8 = undefined;
    const id = try dividerSemanticId(&id_buffer, self.activePresentation().key, divider.divider_id);
    const element = self.ui_tree.byId(.{ .value = id }) orelse return false;
    const start = elementCenter(element, self.window.state.scale);
    const cell = self.fonts.metrics().cell;
    const scale = self.window.state.scale.factor;
    var finish_x = start.x;
    var finish_y = start.y;
    switch (divider.split) {
        .right => finish_x += @as(f32, @floatFromInt(cells * @as(i32, @intCast(cell.width_px)))) / scale,
        .down => finish_y += @as(f32, @floatFromInt(cells * @as(i32, @intCast(cell.height_px)))) / scale,
    }
    return try postButton(self, io, out, .{ .button = .left, .action = .press, .x = start.x, .y = start.y }) and
        try postMotion(self, io, out, .{ .buttons = .{ .left = true }, .x = finish_x, .y = finish_y }) and
        try postButton(self, io, out, .{ .button = .left, .action = .release, .x = finish_x, .y = finish_y });
}

/// Exercise TASK-30 through production bindings, semantic hit testing, the
/// real workspace model, PTYs and the pane compositor.
fn panesTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    try self.drawFrame();
    panesCheck(out, &failures, try waitForPanes(self, io, out, .{ .focused_text = "PANE-PWD:" }), "the first real pane child became ready", .{});
    panesCheck(out, &failures, try waitForPanes(self, io, out, .{ .cwd = "/tmp" }), "the source pane reported tracked cwd /tmp", .{});

    const tab_id = self.activeWorkspace().activeTabId() orelse return error.SessionNotFound;
    const root_pane = self.activeWorkspace().focusedPaneId(tab_id) orelse return error.SessionNotFound;
    const root_session = self.activeWorkspace().focusedPaneSessionId(tab_id) orelse return error.SessionNotFound;
    const split_right_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    panesCheck(out, &failures, try postKey(self, io, out, if (self.binding_profile == .macos) 'd' else 'e', split_right_mods), "the split-right binding travelled through SDL", .{});
    const right_pane = self.activeWorkspace().focusedPaneId(tab_id) orelse return error.SessionNotFound;
    const right_session = self.activeWorkspace().focusedPaneSessionId(tab_id) orelse return error.SessionNotFound;
    panesCheck(out, &failures, right_pane != root_pane and right_session != root_session and
        try waitForPanes(self, io, out, .{ .focused_text = "PANE-PWD:/tmp" }), "split right kept stable ids and spawned in the actual inherited cwd /tmp", .{});

    const split_down_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    panesCheck(out, &failures, try postKey(self, io, out, if (self.binding_profile == .macos) 'd' else 'o', split_down_mods), "the split-down binding created a nested pane", .{});
    const lower_pane = self.activeWorkspace().focusedPaneId(tab_id) orelse return error.SessionNotFound;
    const lower_session = self.activeWorkspace().focusedPaneSessionId(tab_id) orelse return error.SessionNotFound;
    panesCheck(out, &failures, lower_pane != root_pane and lower_pane != right_pane and
        lower_session != root_session and lower_session != right_session and
        self.activeWorkspace().tab(tab_id).?.paneCount() == 3 and
        try waitForPanes(self, io, out, .{ .focused_text = "PANE-PWD:/tmp" }), "nested layout retained three distinct pane/session identities", .{});

    var root_id_buffer: [pane_semantic_capacity]u8 = undefined;
    const root_id = try paneSemanticId(&root_id_buffer, self.activePresentation().key, root_pane);
    var trace: ClipboardTrace = .{};
    defer trace.deinit(self.allocator);
    self.trace = &trace;
    defer self.trace = null;
    const sent_before_click = trace.sent.items.len;
    panesCheck(out, &failures, try clickTabsElement(self, io, out, root_id) and
        self.activeWorkspace().focusedPaneId(tab_id) == root_pane and
        trace.sent.items.len > sent_before_click, "clicking an inactive pane focused it and delivered the same press to terminal mouse reporting", .{});

    const focus_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .alt = true, .super = true },
        .linux_windows => .{ .alt = true },
    };
    panesCheck(out, &failures, try postNamedKey(self, io, out, .right, focus_mods) and
        self.activeWorkspace().focusedPaneId(tab_id) != root_pane, "directional keyboard focus crossed to the right branch", .{});

    try self.drawFrame();
    if (self.divider_layout_count == 0) return error.InvalidGeometry;
    const divider = self.divider_layouts[0];
    const divider_before = divider.rect;
    const size_before_drag = self.activeLive().terminal().gridSize();
    panesCheck(out, &failures, try dragPaneDivider(self, io, out, divider, 1), "the semantic one-cell divider accepted a real pointer drag", .{});
    const divider_after = self.divider_layouts[0].rect;
    const size_after_drag = self.activeLive().terminal().gridSize();
    panesCheck(out, &failures, !std.meta.eql(divider_before, divider_after) and
        !std.meta.eql(size_before_drag, size_after_drag), "divider drag changed layout and the focused PTY size", .{});

    const resize_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .ctrl = true, .super = true },
        .linux_windows => .{ .ctrl = true, .alt = true },
    };
    const size_before_key = self.activeLive().terminal().gridSize();
    panesCheck(out, &failures, try postNamedKey(self, io, out, .left, resize_mods), "the keyboard resize binding travelled through SDL", .{});
    panesCheck(out, &failures, !std.meta.eql(size_before_key, self.activeLive().terminal().gridSize()), "keyboard resize changed the focused PTY geometry", .{});

    const hidden_session = self.activePresentation().active_session_id;
    try self.window.postTextInput("hidden");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    _ = try clickTabsElement(self, io, out, root_id);
    const zoom_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    panesCheck(out, &failures, try postNamedKey(self, io, out, .enter, zoom_mods) and
        self.activeWorkspace().tab(tab_id).?.zoomedPaneId() == root_pane and
        self.activeWorkspace().tab(tab_id).?.paneCount() == 3, "zoom filled the tab without replacing sessions", .{});
    panesCheck(out, &failures, try waitForPanes(self, io, out, .{ .session_text = .{ .id = hidden_session, .text = "PANE-ECHO:hidden" } }), "a pane hidden by zoom continued pumping output", .{});
    panesCheck(out, &failures, try postNamedKey(self, io, out, .enter, zoom_mods) and
        self.activeWorkspace().tab(tab_id).?.zoomedPaneId() == null and
        self.activeWorkspace().paneSessionId(tab_id, lower_pane) == lower_session, "unzoom restored the same nested sessions", .{});
    panesCheck(out, &failures, try clickTabsElement(self, io, out, "panes.zoom") and
        self.activeWorkspace().tab(tab_id).?.zoomedPaneId() == root_pane and
        self.activeWorkspace().tab(tab_id).?.paneCount() == 3, "the clickable sidebar zoomed the focused pane through the named action", .{});
    panesCheck(out, &failures, try clickTabsElement(self, io, out, "panes.zoom") and
        self.activeWorkspace().tab(tab_id).?.zoomedPaneId() == null and
        self.activeWorkspace().paneSessionId(tab_id, lower_pane) == lower_session, "the clickable sidebar unzoomed without replacing sessions", .{});

    var lower_id_buffer: [pane_semantic_capacity]u8 = undefined;
    const lower_id = try paneSemanticId(&lower_id_buffer, self.activePresentation().key, lower_pane);
    const zoom_element = self.ui_tree.byId(.{ .value = "panes.zoom" }) orelse return error.ElementNotFound;
    const lower_element = self.ui_tree.byId(.{ .value = lower_id }) orelse return error.ElementNotFound;
    const zoom_point = elementCenter(zoom_element, self.window.state.scale);
    const lower_point = elementCenter(lower_element, self.window.state.scale);
    const sent_before_ui_drag = trace.sent.items.len;
    const pressed_zoom = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = zoom_point.x, .y = zoom_point.y });
    const dragged_over_inactive_pane = try postMotion(self, io, out, .{ .buttons = .{ .left = true }, .x = lower_point.x, .y = lower_point.y });
    const released_over_inactive_pane = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = lower_point.x, .y = lower_point.y });
    panesCheck(out, &failures, pressed_zoom and dragged_over_inactive_pane and released_over_inactive_pane and
        trace.sent.items.len == sent_before_ui_drag and
        self.activeWorkspace().focusedPaneId(tab_id) == root_pane and
        self.activeWorkspace().tab(tab_id).?.zoomedPaneId() == null, "a sidebar-owned press kept drag motion and release out of the inactive terminal", .{});

    _ = try clickTabsElement(self, io, out, lower_id);
    try self.window.postTextInput("busy-pane");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    panesCheck(out, &failures, try waitForPanes(self, io, out, .{ .session_text = .{ .id = lower_session, .text = "busy-pane" } }), "the close fixture entered a shell-marked foreground phase", .{});
    const close_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    panesCheck(out, &failures, try postKey(self, io, out, 'x', close_mods) and
        try waitForPanes(self, io, out, .{ .element = "tab-close.dialog" }) and
        self.pending_close_pane != null, "the pane-close binding opened the shared confirmation modal", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    panesCheck(out, &failures, self.pending_close_pane == null and
        self.activeWorkspace().paneSessionId(tab_id, lower_pane) == lower_session, "Escape cancelled the keyboard-requested close without changing the tree", .{});
    panesCheck(out, &failures, try clickTabsElement(self, io, out, "panes.close") and
        try waitForPanes(self, io, out, .{ .element = "tab-close.dialog" }) and
        self.pending_close_pane != null, "closing a running pane opened the shared confirmation modal", .{});
    const routes_before_modal = self.terminal_key_route_count;
    try self.window.postTextInput("LEAK");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postKey(self, io, out, 'x', .{});
    panesCheck(out, &failures, self.terminal_key_route_count == routes_before_modal and self.pending_committed_text.len == 0, "the pane-close modal isolated committed and key input", .{});
    const panes_before_modal_click = self.activeWorkspace().tab(tab_id).?.paneCount();
    _ = try clickTabsElement(self, io, out, "panes.split-right");
    panesCheck(out, &failures, self.activeWorkspace().tab(tab_id).?.paneCount() == panes_before_modal_click and self.pending_close_pane != null, "the pane-close modal isolated pointer input", .{});
    const viewport_before_modal_wheel = self.activeLive().terminal().viewport().offset;
    _ = try postWheelEvent(self, io, out, 3);
    panesCheck(out, &failures, self.activeLive().terminal().viewport().offset == viewport_before_modal_wheel, "the pane-close modal isolated wheel input", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    panesCheck(out, &failures, self.pending_close_pane == null and self.activeWorkspace().paneSessionId(tab_id, lower_pane) == lower_session, "Escape cancelled pane close without changing the tree", .{});

    _ = try clickTabsElement(self, io, out, "panes.close");
    _ = try postNamedKey(self, io, out, .tab, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    panesCheck(out, &failures, self.activeWorkspace().paneSessionId(tab_id, lower_pane) == null and
        self.activeWorkspace().tab(tab_id).?.paneCount() == 2 and self.activePresentation().pane_renderers.items.len == 2, "confirmation closed the pane, renderer and session and rebalanced its sibling", .{});

    panesCheck(out, &failures, try clickTabsElement(self, io, out, "panes.close") and
        self.activeWorkspace().tab(tab_id).?.paneCount() == 1 and
        self.activeWorkspace().focusedPaneSessionId(tab_id) == root_session and
        self.activePresentation().active_session_id == root_session and self.ui_tree.focusedElement() == null and
        self.ui_key_state.len == 0, "closing the idle sibling directly rebalanced to one terminal-owned final leaf", .{});
    try self.window.postTextInput("final-busy");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    panesCheck(out, &failures, try waitForPanes(self, io, out, .{ .session_text = .{ .id = root_session, .text = "final-busy" } }), "the final pane entered a foreground phase before close", .{});
    _ = try clickTabsElement(self, io, out, "panes.close");
    panesCheck(out, &failures, self.pending_close_tab_id == tab_id and self.pending_close_pane == null, "closing the final pane delegated to the tab close policy", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    panesCheck(out, &failures, self.activeWorkspace().tab(tab_id).?.paneCount() == 1 and !self.requested_shutdown, "cancelling final-pane close left the tab usable", .{});

    const mouse_split = try clickTabsElement(self, io, out, "panes.split-right");
    const final_right_session = self.activeWorkspace().focusedPaneSessionId(tab_id) orelse return error.SessionNotFound;
    panesCheck(out, &failures, mouse_split and
        final_right_session != root_session and
        self.activeWorkspace().tab(tab_id).?.paneCount() == 2 and
        try waitForPanes(self, io, out, .{ .session_text = .{ .id = final_right_session, .text = "PANE-PWD:/tmp" } }), "the clickable sidebar split right through the named action", .{});
    _ = try postKey(self, io, out, if (self.binding_profile == .macos) 'd' else 'o', split_down_mods);
    const final_lower_session = self.activeWorkspace().focusedPaneSessionId(tab_id) orelse return error.SessionNotFound;
    _ = try waitForPanes(self, io, out, .{ .session_text = .{ .id = final_lower_session, .text = "PANE-PWD:/tmp" } });
    try self.drawFrame();
    panesCheck(out, &failures, self.pane_layout_count == 3 and self.divider_layout_count == 2, "the final frame contains three panes and two one-cell dividers", .{});
    _ = try self.capture();
    out.print("panes-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

const scratchpad_test_budget_ms: i64 = 5000;

const ScratchpadWait = union(enum) {
    child,
    prompt,
    replacement: *anyopaque,
    text: []const u8,
    element: []const u8,
};

fn scratchpadWaitMet(self: *App, condition: ScratchpadWait) !bool {
    const scratchpad = self.scratchpadLive() orelse return false;
    return switch (condition) {
        .child => scratchpad.child() != null,
        .prompt => prompt: {
            try scratchpad.terminal().refresh(self.allocator);
            const has_prompt = scratchpad.terminal().visibleTextContains("$") or
                scratchpad.terminal().visibleTextContains("#");
            break :prompt scratchpad.child() != null and has_prompt and
                !self.activeWorkspace().needsPump();
        },
        .replacement => |old_ptr| if (scratchpad.child()) |child| child.ptr != old_ptr else false,
        .text => |text| text_found: {
            try scratchpad.terminal().refresh(self.allocator);
            break :text_found scratchpad.terminal().visibleTextContains(text);
        },
        .element => |id| self.ui_tree.byId(.{ .value = id }) != null,
    };
}

fn waitForScratchpad(self: *App, io: Io, out: *Writer, condition: ScratchpadWait) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + scratchpad_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        if (try scratchpadWaitMet(self, condition)) return true;
        const event = self.window.pump(@min(eventWaitBudget(io, deadline, false), idle_tick_ms));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) return try scratchpadWaitMet(self, condition);
    }
}

fn scratchpadCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("scratchpad-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn postScratchpadText(self: *App, io: Io, out: *Writer, text: [:0]const u8) !bool {
    try self.window.postTextInput(text);
    return pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
}

fn scratchpadChord(self: *App, io: Io, out: *Writer, ninety: bool) !bool {
    const mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = ninety, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = ninety },
    };
    return postKey(self, io, out, '`', mods);
}

/// Exercise the real workspace scratchpad through its shipped keys, semantic
/// controls, SDL input path, retained terminal renderer and PTY replacement.
fn scratchpadTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    scratchpadCheck(out, &failures, try waitForScratchpad(self, io, out, .child), "the hidden workspace scratchpad started its interactive shell", .{});
    const scratchpad = self.scratchpadLive() orelse return 1;
    const original_child = scratchpad.child() orelse return 1;
    const workspace_key = self.activePresentation().key;
    var scratchpad_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const scratchpad_semantic = try scratchpadSemanticId(&scratchpad_id_buffer, workspace_key, "");
    var scratchpad_terminal_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const scratchpad_terminal_semantic = try scratchpadSemanticId(&scratchpad_terminal_id_buffer, workspace_key, "terminal");
    var scratchpad_restart_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const scratchpad_restart_semantic = try scratchpadSemanticId(&scratchpad_restart_id_buffer, workspace_key, "restart");
    var scratchpad_hide_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const scratchpad_hide_semantic = try scratchpadSemanticId(&scratchpad_hide_id_buffer, workspace_key, "hide");

    scratchpadCheck(out, &failures, try scratchpadChord(self, io, out, false) and
        self.activePresentation().scratchpad_presentation == .fifty and
        try waitForScratchpad(self, io, out, .{ .element = scratchpad_terminal_semantic }), "the 50 percent binding presented the semantic scratchpad terminal", .{});
    const half_inner = self.scratchpadInnerRect() orelse return 1;
    scratchpadCheck(out, &failures, @as(u32, scratchpad.terminal().gridSize().rows) == half_inner.height and
        @as(u32, scratchpad.terminal().gridSize().cols) == half_inner.width, "the 50 percent dock resized the same PTY to its bordered inner rectangle", .{});

    _ = try postScratchpadText(self, io, out, "stty -echo");
    _ = try postNamedKey(self, io, out, .enter, .{});
    _ = try postScratchpadText(self, io, out, "printf 'SCRATCH-ONE\\n'; scratch_state=kept; read scratch_hold; printf 'SCRATCH-HOLD:%s\\n' \"$scratch_hold\"");
    _ = try postNamedKey(self, io, out, .enter, .{});
    scratchpadCheck(out, &failures, try waitForScratchpad(self, io, out, .{ .text = "SCRATCH-ONE" }), "a foreground program produced output in the scratchpad", .{});

    scratchpadCheck(out, &failures, try scratchpadChord(self, io, out, false) and
        self.activePresentation().scratchpad_presentation == .hidden and
        self.ui_tree.byId(.{ .value = scratchpad_semantic }) == null, "repeating the 50 percent binding hid the view without terminating it", .{});
    scratchpadCheck(out, &failures, try scratchpadChord(self, io, out, true) and
        self.activePresentation().scratchpad_presentation == .ninety and
        self.scratchpadLive().?.child().?.ptr == original_child.ptr and
        try waitForScratchpad(self, io, out, .{ .text = "SCRATCH-ONE" }), "the 90 percent binding restored the same process and retained output", .{});
    const ninety_inner = self.scratchpadInnerRect() orelse return 1;
    scratchpadCheck(out, &failures, ninety_inner.height > half_inner.height and
        @as(u32, scratchpad.terminal().gridSize().rows) == ninety_inner.height, "the second binding expanded the retained scratchpad to about 90 percent", .{});

    _ = try postScratchpadText(self, io, out, "resumed");
    _ = try postNamedKey(self, io, out, .enter, .{});
    scratchpadCheck(out, &failures, try waitForScratchpad(self, io, out, .{ .text = "SCRATCH-HOLD:resumed" }), "the foreground read survived hide and resumed with its state intact", .{});
    _ = try postScratchpadText(self, io, out, "printf 'SCRATCH-STATE:%s\\n' \"$scratch_state\"");
    _ = try postNamedKey(self, io, out, .enter, .{});
    scratchpadCheck(out, &failures, try waitForScratchpad(self, io, out, .{ .text = "SCRATCH-STATE:kept" }), "shell state remained alive across both presentations", .{});
    try self.activeLive().terminal().refresh(self.allocator);
    scratchpadCheck(out, &failures, !self.activeLive().terminal().visibleTextContains("resumed"), "committed text and Enter reached only the presented scratchpad", .{});

    _ = try postNamedKey(self, io, out, .escape, .{});
    scratchpadCheck(out, &failures, self.activePresentation().scratchpad_presentation == .hidden, "Escape hid the scratchpad without stopping its child", .{});
    _ = try scratchpadChord(self, io, out, true);
    const sidebar_before = self.sidebar_visible;
    const dispatch_before = self.action_dispatch_count;
    const sidebar_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    _ = try postKey(self, io, out, 'b', sidebar_mods);
    scratchpadCheck(out, &failures, self.sidebar_visible == sidebar_before and
        self.action_dispatch_count == dispatch_before, "visible scratchpad modal routing blocked underlying key actions", .{});
    const active_before = self.activePresentation().active_session_id;
    var active_tab_semantic_buffer: [workspace_semantic_capacity]u8 = undefined;
    const active_tab_semantic = try tabSemanticId(
        &active_tab_semantic_buffer,
        workspace_key,
        self.activeWorkspace().activeTabId().?,
    );
    _ = try clickTabsElement(self, io, out, active_tab_semantic);
    scratchpadCheck(out, &failures, self.activePresentation().active_session_id == active_before, "pointer input outside the dock terminal could not activate underlying workspace UI", .{});

    scratchpadCheck(out, &failures, try paletteChord(self, io, out) and self.paletteVisible(), "the command palette opened over the visible scratchpad", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    scratchpadCheck(out, &failures, !self.paletteVisible() and self.scratchpadVisible() and
        self.ui_key_state.len == 0, "palette Escape kept its release ownership without hiding the scratchpad", .{});
    scratchpadCheck(out, &failures, try paletteChord(self, io, out) and self.paletteVisible(), "the palette reopened immediately after its Escape gesture completed", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});

    scratchpadCheck(out, &failures, try clickTabsElement(self, io, out, scratchpad_restart_semantic), "the clickable restart control dispatched through the semantic tree", .{});
    scratchpadCheck(out, &failures, try waitForScratchpad(self, io, out, .{ .replacement = original_child.ptr }), "restart atomically replaced the scratchpad child", .{});
    const restarted = self.scratchpadLive() orelse return 1;
    try restarted.terminal().refresh(self.allocator);
    scratchpadCheck(out, &failures, !restarted.terminal().visibleTextContains("SCRATCH-ONE"), "restart installed a fresh terminal instead of retaining old output", .{});
    _ = try postScratchpadText(self, io, out, "stty -echo");
    _ = try postNamedKey(self, io, out, .enter, .{});
    _ = try postScratchpadText(self, io, out, "printf 'SCRATCH-FRESH\\n'");
    _ = try postNamedKey(self, io, out, .enter, .{});
    scratchpadCheck(out, &failures, try waitForScratchpad(self, io, out, .{ .text = "SCRATCH-FRESH" }), "the fresh shell accepted terminal input after restart", .{});

    scratchpadCheck(out, &failures, try clickTabsElement(self, io, out, scratchpad_hide_semantic) and
        self.activePresentation().scratchpad_presentation == .hidden, "the clickable hide control removed only the presentation", .{});
    _ = try scratchpadChord(self, io, out, true);
    try self.drawFrame();
    _ = try self.capture();
    const final_overlay = self.overlayView();
    const final_inner = self.scratchpadInnerRect() orelse return 1;
    var underlay_paint_leaked = false;
    for (final_overlay.cells) |cell| {
        if (cell.position.col >= final_inner.x and cell.position.col < final_inner.right() and
            cell.position.row >= final_inner.y and cell.position.row < final_inner.bottom())
        {
            underlay_paint_leaked = true;
            break;
        }
    }
    scratchpadCheck(out, &failures, self.ui_tree.byId(.{ .value = scratchpad_semantic }) != null and
        self.ui_tree.byId(.{ .value = scratchpad_restart_semantic }) != null and
        self.ui_tree.byId(.{ .value = scratchpad_hide_semantic }) != null, "the final captured frame contains the 90 percent dock and both mouse controls", .{});
    scratchpadCheck(out, &failures, !underlay_paint_leaked, "the transparent dock masks all underlying UI paint without covering terminal output", .{});

    out.print("scratchpad-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

fn paletteCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("palette-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

/// The deterministic peer behind every terminal created by `--palette-test`.
/// Its OSC 7 cwd makes New tab and Split pane exercise the real inherited-cwd
/// spawn path, while the exact line echo exposes any modal input leakage.
const palette_test_script =
    "stty -echo; " ++
    "printf '\\033]7;file://localhost/tmp\\007PALETTE-READY:%s\\r\\n' \"$PWD\"; " ++
    "while IFS= read -r line; do printf 'PALETTE-ECHO:%s\\r\\n' \"$line\"; done";

fn paletteChord(self: *App, io: Io, out: *Writer) !bool {
    const mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    return postKey(self, io, out, 'p', mods);
}

fn definitionIndex(self: *const App, action_name: []const u8) ?usize {
    for (self.actions.definitions(), 0..) |definition, index| {
        if (std.mem.eql(u8, definition.name, action_name)) return index;
    }
    return null;
}

fn paletteContainsDefinition(self: *const App, action_name: []const u8) bool {
    for (self.palette_model.results()) |index| {
        if (std.mem.eql(u8, self.actions.definitions()[index].name, action_name)) return true;
    }
    return false;
}

fn postPaletteText(self: *App, io: Io, out: *Writer, text: [:0]const u8) !bool {
    try self.window.postTextInput(text);
    return pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
}

/// Exercise TASK-31 through the production keybinding resolver, semantic tree,
/// action registry, workspace model and real SDL keyboard/mouse event path.
fn paletteTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    try self.drawFrame();
    paletteCheck(out, &failures, try waitForPanes(self, io, out, .{ .focused_text = "PALETTE-READY:" }), "the first real palette-test child became ready", .{});

    paletteCheck(out, &failures, try paletteChord(self, io, out), "the shipped palette chord travelled through SDL", .{});
    const dialog = self.ui_tree.byId(.{ .value = "palette.dialog" });
    const query = self.ui_tree.byId(.{ .value = "palette.query" });
    const centered = if (dialog) |element|
        @abs((element.bounds.x * 2 + @as(i32, @intCast(element.bounds.width))) - @as(i32, @intCast(self.size.width))) <=
            @as(i32, @intCast(self.fonts.metrics().cell.width_px)) and
            @abs((element.bounds.y * 2 + @as(i32, @intCast(element.bounds.height))) - @as(i32, @intCast(self.size.height))) <=
                @as(i32, @intCast(self.fonts.metrics().cell.height_px))
    else
        false;
    paletteCheck(out, &failures, self.paletteVisible() and dialog != null and centered and
        query != null and query.?.state.focused, "the centered semantic dialog opened with its filter focused", .{});
    paletteCheck(out, &failures, paletteContainsDefinition(self, tab_new_action) and
        paletteContainsDefinition(self, pane_split_action) and
        self.actions.lookup("settings.open") == null and self.actions.lookup("theme.select") == null and
        self.actions.lookup("font.select") == null and self.actions.lookup("remote.connect") == null, "New tab and Split pane are present while unshipped commands are absent", .{});

    paletteCheck(out, &failures, try postPaletteText(self, io, out, "newtab"), "fuzzy query text travelled through SDL", .{});
    const selected_new = self.palette_model.selectedDefinition();
    const new_definition_index = definitionIndex(self, tab_new_action) orelse return 1;
    var new_id_storage: [palette_semantic_capacity]u8 = undefined;
    const new_id = try std.fmt.bufPrint(&new_id_storage, "palette.action.{d}", .{new_definition_index});
    const new_row = self.ui_tree.byId(.{ .value = new_id });
    const expected_chord = if (self.binding_profile == .macos) "Cmd+T" else "Ctrl+Shift+T";
    paletteCheck(out, &failures, std.mem.eql(u8, self.palette_query.text(), "newtab") and
        self.palette_model.results().len == 1 and selected_new != null and
        std.mem.eql(u8, selected_new.?.name, tab_new_action) and new_row != null and
        std.mem.indexOf(u8, new_row.?.label, expected_chord) != null, "fuzzy filtering selected New tab and displayed its bound key", .{});

    const tabs_before_keyboard = self.activeWorkspace().tabCount();
    paletteCheck(out, &failures, try postNamedKey(self, io, out, .enter, .{}) and
        !self.paletteVisible() and self.activeWorkspace().tabCount() == tabs_before_keyboard + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", tab_new_action), "Enter ran the selected command and created a tab", .{});
    const keyboard_tab = self.activeWorkspace().activeTabId() orelse return error.SessionNotFound;
    const keyboard_session = self.activeWorkspace().focusedPaneSessionId(keyboard_tab) orelse return error.SessionNotFound;
    paletteCheck(out, &failures, try waitForPanes(self, io, out, .{ .session_text = .{
        .id = keyboard_session,
        .text = "PALETTE-READY:/tmp",
    } }), "the palette-created tab attached its inherited-cwd PTY before the next command", .{});

    _ = try paletteChord(self, io, out);
    const mru = self.palette_model.selectedDefinition();
    paletteCheck(out, &failures, mru != null and std.mem.eql(u8, mru.?.name, tab_new_action), "reopening with an empty query ranked the last command first", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    paletteCheck(out, &failures, !self.paletteVisible() and self.ui_tree.byId(.{ .value = "palette.dialog" }) == null, "Escape closed the palette", .{});

    _ = try paletteChord(self, io, out);
    _ = try postPaletteText(self, io, out, "splitpane");
    _ = try postNamedKey(self, io, out, .enter, .{});
    const active_tab = self.activeWorkspace().activeTabId() orelse return 1;
    const panes_before_choice = self.activeWorkspace().tab(active_tab).?.paneCount();
    const split_definition_index = definitionIndex(self, pane_split_action) orelse return 1;
    var right_choice_storage: [palette_semantic_capacity]u8 = undefined;
    var down_choice_storage: [palette_semantic_capacity]u8 = undefined;
    const right_choice_id = try std.fmt.bufPrint(&right_choice_storage, "palette.choice.{d}.0", .{split_definition_index});
    const down_choice_id = try std.fmt.bufPrint(&down_choice_storage, "palette.choice.{d}.1", .{split_definition_index});
    paletteCheck(out, &failures, self.palette_step == .choices and
        self.ui_tree.byId(.{ .value = right_choice_id }) != null and
        self.ui_tree.byId(.{ .value = down_choice_id }) != null, "Split pane opened its nested direction choices", .{});
    paletteCheck(out, &failures, try clickTabsElement(self, io, out, down_choice_id) and
        !self.paletteVisible() and self.activeWorkspace().tab(active_tab).?.paneCount() == panes_before_choice + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", pane_split_action), "clicking Down dispatched the nested argument and split the pane", .{});
    const split_session = self.activeWorkspace().focusedPaneSessionId(active_tab) orelse return error.SessionNotFound;
    paletteCheck(out, &failures, try waitForPanes(self, io, out, .{ .session_text = .{
        .id = split_session,
        .text = "PALETTE-READY:/tmp",
    } }), "the palette-created pane attached its inherited-cwd PTY before the next command", .{});

    _ = try paletteChord(self, io, out);
    _ = try postPaletteText(self, io, out, "gototab");
    _ = try postNamedKey(self, io, out, .enter, .{});
    paletteCheck(out, &failures, self.palette_step == .input and
        self.ui_tree.byId(.{ .value = "palette.argument" }) != null and
        self.ui_tree.focusedElement() != null and
        std.mem.eql(u8, self.ui_tree.focusedElement().?.id.value, "palette.argument"), "Go to tab opened and focused its free-text argument", .{});
    _ = try postPaletteText(self, io, out, "1");
    _ = try postNamedKey(self, io, out, .enter, .{});
    const first_tab = self.activeWorkspace().tabAt(0) orelse return 1;
    paletteCheck(out, &failures, !self.paletteVisible() and self.activeWorkspace().activeTabId() == first_tab.id(), "the collected tab number reached the action handler", .{});

    _ = try paletteChord(self, io, out);
    const tabs_before_isolation = self.activeWorkspace().tabCount();
    const terminal_routes_before = self.terminal_key_route_count;
    const new_tab_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    _ = try postKey(self, io, out, 't', new_tab_mods);
    paletteCheck(out, &failures, self.paletteVisible() and
        self.activeWorkspace().tabCount() == tabs_before_isolation and
        self.terminal_key_route_count == terminal_routes_before, "the modal palette blocked an underlying action binding and terminal route", .{});

    const outside = cellPosition(self, 0, 0);
    _ = try postButton(self, io, out, .{ .button = .left, .action = .press, .x = outside.x, .y = outside.y });
    _ = try postButton(self, io, out, .{ .button = .left, .action = .release, .x = outside.x, .y = outside.y });
    paletteCheck(out, &failures, !self.paletteVisible() and !self.palette_pointer_owned, "an outside click closed the palette and owned the matching release", .{});

    _ = try paletteChord(self, io, out);
    _ = try postPaletteText(self, io, out, "newtab");
    const tabs_before_mouse = self.activeWorkspace().tabCount();
    paletteCheck(out, &failures, try clickTabsElement(self, io, out, new_id) and
        self.activeWorkspace().tabCount() == tabs_before_mouse + 1 and !self.paletteVisible(), "clicking a fuzzy result ran the command through its semantic row", .{});
    const mouse_tab = self.activeWorkspace().activeTabId() orelse return error.SessionNotFound;
    const mouse_session = self.activeWorkspace().focusedPaneSessionId(mouse_tab) orelse return error.SessionNotFound;
    paletteCheck(out, &failures, try waitForPanes(self, io, out, .{ .session_text = .{
        .id = mouse_session,
        .text = "PALETTE-READY:/tmp",
    } }), "the mouse-created tab attached its real PTY before further palette input", .{});

    _ = try paletteChord(self, io, out);
    _ = try postPaletteText(self, io, out, "splitpane");
    _ = try postNamedKey(self, io, out, .enter, .{});
    const routes_before_choice_text = self.terminal_key_route_count;
    _ = try postPaletteText(self, io, out, "LEAK");
    paletteCheck(out, &failures, self.palette_step == .choices and
        self.terminal_key_route_count == routes_before_choice_text and self.pending_committed_text.len == 0, "committed text in a choice step could not leak to the terminal", .{});

    _ = try postNamedKey(self, io, out, .escape, .{});
    try self.window.postTextInput("terminal-probe");
    const probe_text_delivered = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    const probe_enter_delivered = try postNamedKey(self, io, out, .enter, .{});
    const probe_echoed = try waitForPanes(self, io, out, .{ .session_text = .{
        .id = mouse_session,
        .text = "PALETTE-ECHO:terminal-probe",
    } });
    const isolated_live = self.activeWorkspace().sessionById(mouse_session) orelse return error.SessionNotFound;
    try isolated_live.terminal().refresh(self.allocator);
    paletteCheck(out, &failures, !self.paletteVisible() and probe_text_delivered and probe_enter_delivered and probe_echoed and
        !isolated_live.terminal().visibleTextContains("PALETTE-ECHO:splitpane") and
        !isolated_live.terminal().visibleTextContains("PALETTE-ECHO:LEAK"), "query and choice text stayed out of the PTY, then ordinary terminal input completed an exact round trip", .{});

    _ = try paletteChord(self, io, out);
    _ = try postPaletteText(self, io, out, "splitpane");
    _ = try postNamedKey(self, io, out, .enter, .{});
    try self.drawFrame();
    _ = try self.capture();
    paletteCheck(out, &failures, self.ui_tree.byId(.{ .value = "palette.dialog" }) != null and
        self.ui_tree.byId(.{ .value = right_choice_id }) != null, "the final captured frame contains the centered palette and nested choices", .{});

    out.print("palette-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

/// The initial terminal peer for `--workspaces-test`. Workspaces created by
/// the scenario deliberately use the independent interactive-shell spec;
/// splits in either workspace use this fixed line-oriented peer.
const workspaces_test_script =
    "stty -echo; " ++
    "printf 'WORKSPACE-PTY-READY:%s\\r\\n' \"$PWD\"; " ++
    "while IFS= read -r line; do printf 'WORKSPACE-ECHO:%s\\r\\n' \"$line\"; done";

const workspaces_test_budget_ms: i64 = 8000;

const WorkspacesWait = union(enum) {
    count: usize,
    active: workspace.WorkspaceKey,
    session_child: struct { key: workspace.WorkspaceKey, id: session.SessionId },
    scratchpad_child: workspace.WorkspaceKey,
    session_text: struct { key: workspace.WorkspaceKey, id: session.SessionId, text: []const u8 },
    scratchpad_text: struct { key: workspace.WorkspaceKey, text: []const u8 },
    settled: workspace.WorkspaceKey,
    removed: workspace.WorkspaceKey,
};

fn workspacesWaitMet(self: *App, condition: WorkspacesWait) !bool {
    return switch (condition) {
        .count => |count| self.workspace_registry.count() == count,
        .active => |key| if (self.workspace_registry.activeKey()) |active| active == key else false,
        .session_child => |wanted| child: {
            const model = self.workspace_registry.byKey(wanted.key) orelse break :child false;
            const live = model.sessionById(wanted.id) orelse break :child false;
            break :child live.child() != null;
        },
        .scratchpad_child => |key| child: {
            const model = self.workspace_registry.byKey(key) orelse break :child false;
            const live = model.sessionById(model.scratchpadId()) orelse break :child false;
            break :child live.child() != null;
        },
        .session_text => |wanted| found: {
            const model = self.workspace_registry.byKey(wanted.key) orelse break :found false;
            const live = model.sessionById(wanted.id) orelse break :found false;
            try live.terminal().refresh(self.allocator);
            break :found live.terminal().visibleTextContains(wanted.text);
        },
        .scratchpad_text => |wanted| found: {
            const model = self.workspace_registry.byKey(wanted.key) orelse break :found false;
            const live = model.sessionById(model.scratchpadId()) orelse break :found false;
            try live.terminal().refresh(self.allocator);
            break :found live.terminal().visibleTextContains(wanted.text);
        },
        .settled => |key| settled: {
            const model = self.workspace_registry.byKey(key) orelse break :settled false;
            const presentation = self.presentationByKey(key) orelse break :settled false;
            break :settled presentation.load == null and presentation.scratchpad_load == null and
                !model.needsPump();
        },
        .removed => |key| self.workspace_registry.byKey(key) == null and self.presentationByKey(key) == null,
    };
}

fn waitForWorkspaces(self: *App, io: Io, out: *Writer, condition: WorkspacesWait) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + workspaces_test_budget_ms * std.time.ns_per_ms;
    var observed_settled = false;
    while (true) {
        const met = try workspacesWaitMet(self, condition);
        switch (condition) {
            .settled => {
                // A running PTY may become readable just after one nonblocking
                // readiness check. Require a second quiet observation after a
                // normal event-loop wait/service pass before teardown.
                if (met and observed_settled) return true;
                observed_settled = met;
            },
            else => if (met) return true,
        }
        const event = self.window.pump(@min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) {
            const final_met = try workspacesWaitMet(self, condition);
            return switch (condition) {
                .settled => final_met and observed_settled,
                else => final_met,
            };
        }
    }
}

fn workspacesCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("workspaces-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn postWorkspaceTerminalText(self: *App, io: Io, out: *Writer, text: [:0]const u8) !bool {
    try self.window.postTextInput(text);
    return pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
}

fn openWorkspacePaletteCommand(
    self: *App,
    io: Io,
    out: *Writer,
    query: [:0]const u8,
    action_name: []const u8,
) !bool {
    if (!try paletteChord(self, io, out)) return false;
    if (!try postPaletteText(self, io, out, query)) return false;
    const selected = self.palette_model.selectedDefinition() orelse return false;
    if (!std.mem.eql(u8, selected.name, action_name)) return false;
    return postNamedKey(self, io, out, .enter, .{});
}

fn workspacesScreenshotPath(io: Io, buffer: []u8) ![]const u8 {
    var id_buffer: [path_capacity]u8 = undefined;
    const id = try generateRunId(io, &id_buffer);
    return std.fmt.bufPrint(
        buffer,
        "{s}{c}workspaces-test-{s}.png",
        .{ fallback_log_dir, std.fs.path.sep, id },
    );
}

/// Exercise TASK-33 through the real action registry, semantic tree, SDL
/// queue, ExecutionContext workers, PTYs and per-workspace render state.
fn workspacesTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    try self.drawFrame();

    const first_key = self.workspace_registry.activeKey() orelse return 1;
    const first_session = self.activePresentation().active_session_id;
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .session_child = .{
        .key = first_key,
        .id = first_session,
    } }) and try waitForWorkspaces(self, io, out, .{ .scratchpad_child = first_key }) and
        try waitForWorkspaces(self, io, out, .{ .session_text = .{
            .key = first_key,
            .id = first_session,
            .text = "WORKSPACE-PTY-READY:",
        } }), "the initial workspace started independent terminal and scratchpad PTYs", .{});
    const first_model = self.workspace_registry.byKey(first_key) orelse return 1;
    const first_terminal_child = (first_model.sessionById(first_session) orelse return 1).child() orelse return 1;
    const first_scratch_child = (first_model.sessionById(first_model.scratchpadId()) orelse return 1).child() orelse return 1;

    _ = try postWorkspaceTerminalText(self, io, out, "alpha");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .session_text = .{
        .key = first_key,
        .id = first_session,
        .text = "WORKSPACE-ECHO:alpha",
    } }), "terminal input completed a real round trip in the first workspace", .{});

    _ = try scratchpadChord(self, io, out, false);
    _ = try postScratchpadText(self, io, out, "stty -echo; ws_scratch=alpha; printf 'WORKSPACE-SCRATCH-A:%s\\n' \"$ws_scratch\"");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, self.activePresentation().scratchpad_presentation == .fifty and
        try waitForWorkspaces(self, io, out, .{ .scratchpad_text = .{
            .key = first_key,
            .text = "WORKSPACE-SCRATCH-A:alpha",
        } }), "the first scratchpad retained shell state in its 50 percent layout", .{});

    const create_opened = try openWorkspacePaletteCommand(self, io, out, "createworkspace", workspace_create_action);
    workspacesCheck(out, &failures, create_opened and self.palette_step == .input, "the palette opened Create workspace's directory input over the scratchpad", .{});
    if (!create_opened) return 1;
    _ = try postPaletteText(self, io, out, "/tmp");
    _ = try postNamedKey(self, io, out, .enter, .{});
    const second_key = self.workspace_registry.activeKey() orelse return 1;
    workspacesCheck(out, &failures, second_key != first_key and
        try waitForWorkspaces(self, io, out, .{ .count = 2 }) and
        self.activePresentation().scratchpad_presentation == .hidden, "palette creation added and activated one distinct /tmp workspace", .{});
    if (second_key == first_key) return 1;

    const second_session = self.activePresentation().active_session_id;
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .session_child = .{
        .key = second_key,
        .id = second_session,
    } }) and try waitForWorkspaces(self, io, out, .{ .scratchpad_child = second_key }), "the new workspace asynchronously started its terminal and reserved scratchpad", .{});
    _ = try postWorkspaceTerminalText(self, io, out, "stty -echo; printf 'WORKSPACE-SECOND-READY\\n'");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .session_text = .{
        .key = second_key,
        .id = second_session,
        .text = "WORKSPACE-SECOND-READY",
    } }), "the created workspace terminal accepted input through its independent shell", .{});

    workspacesCheck(out, &failures, try clickTabsElement(self, io, out, "panes.split-right"), "the sidebar created a persistent pane layout in the second workspace", .{});
    const second_tab_id = self.activeWorkspace().activeTabId() orelse return 1;
    const split_pane = self.activeWorkspace().focusedPaneId(second_tab_id) orelse return 1;
    const split_session = self.activePresentation().active_session_id;
    workspacesCheck(out, &failures, split_session != second_session and
        try waitForWorkspaces(self, io, out, .{ .session_child = .{
            .key = second_key,
            .id = split_session,
        } }) and try waitForWorkspaces(self, io, out, .{ .session_text = .{
        .key = second_key,
        .id = split_session,
        .text = "WORKSPACE-PTY-READY:/tmp",
    } }), "the split attached a second real PTY in the workspace cwd", .{});
    const split_child = (self.activeWorkspace().sessionById(split_session) orelse return 1).child() orelse return 1;
    var split_pane_id_buffer: [pane_semantic_capacity]u8 = undefined;
    const split_pane_id = try paneSemanticId(&split_pane_id_buffer, second_key, split_pane);
    const split_terminal_focused = try clickTabsElement(self, io, out, split_pane_id);
    _ = try postWorkspaceTerminalText(self, io, out, "beta");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, split_terminal_focused and self.ui_tree.focusedElement() == null and
        try waitForWorkspaces(self, io, out, .{ .session_text = .{
            .key = second_key,
            .id = split_session,
            .text = "WORKSPACE-ECHO:beta",
        } }), "the focused pane kept an independently addressable terminal session", .{});

    _ = try scratchpadChord(self, io, out, true);
    _ = try postScratchpadText(self, io, out, "stty -echo; ws_scratch=beta; printf 'WORKSPACE-SCRATCH-B:%s\\n' \"$ws_scratch\"");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, self.activePresentation().scratchpad_presentation == .ninety and
        try waitForWorkspaces(self, io, out, .{ .scratchpad_text = .{
            .key = second_key,
            .text = "WORKSPACE-SCRATCH-B:beta",
        } }), "the second workspace retained different scratch state in its 90 percent layout", .{});
    const second_model = self.workspace_registry.byKey(second_key) orelse return 1;
    const second_scratch_child = (second_model.sessionById(second_model.scratchpadId()) orelse return 1).child() orelse return 1;
    workspacesCheck(out, &failures, first_scratch_child.ptr != second_scratch_child.ptr, "the two scratchpads own different PTY processes", .{});

    const switch_opened = try openWorkspacePaletteCommand(self, io, out, "switchworkspace", workspace_switch_action);
    workspacesCheck(out, &failures, switch_opened and self.palette_step == .input, "the palette opened Switch workspace's exact-name input", .{});
    if (!switch_opened) return 1;
    _ = try postPaletteText(self, io, out, "default");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .active = first_key }) and
        self.activePresentation().scratchpad_presentation == .fifty and
        (self.activeWorkspace().sessionById(first_session) orelse return 1).child().?.ptr == first_terminal_child.ptr and
        (self.scratchpadLive() orelse return 1).child().?.ptr == first_scratch_child.ptr and
        try waitForWorkspaces(self, io, out, .{ .scratchpad_text = .{
            .key = first_key,
            .text = "WORKSPACE-SCRATCH-A:alpha",
        } }), "palette switching restored the first terminal and its same 50 percent scratchpad", .{});

    _ = try scratchpadChord(self, io, out, false);
    const duplicate_opened = try clickTabsElement(self, io, out, "workspaces.new");
    workspacesCheck(out, &failures, duplicate_opened and self.palette_step == .input, "the clickable sidebar Create workspace control opened its input", .{});
    if (!duplicate_opened) return 1;
    _ = try postPaletteText(self, io, out, "/tmp/");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .active = second_key }) and
        self.workspace_registry.count() == 2 and self.activePresentation().scratchpad_presentation == .ninety and
        self.activeWorkspace().tab(second_tab_id).?.paneCount() == 2 and
        self.activeWorkspace().focusedPaneId(second_tab_id) == split_pane and
        self.activePresentation().active_session_id == split_session and
        (self.activeLive().child() orelse return 1).ptr == split_child.ptr, "creating an already-open cwd activated it without duplication and restored its pane layout", .{});
    _ = try scratchpadChord(self, io, out, true);

    const rename_opened = try clickTabsElement(self, io, out, "workspaces.rename");
    workspacesCheck(out, &failures, rename_opened and self.palette_step == .input, "the clickable sidebar Rename workspace control opened its input", .{});
    if (!rename_opened) return 1;
    _ = try postPaletteText(self, io, out, "secondary");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, self.workspace_registry.keyForName("secondary") == second_key, "sidebar rename committed the trimmed unique display name", .{});

    const palette_rename_opened = try openWorkspacePaletteCommand(self, io, out, "renameworkspace", workspace_rename_action);
    workspacesCheck(out, &failures, palette_rename_opened and self.palette_step == .input, "the palette exposed the same Rename workspace action", .{});
    if (!palette_rename_opened) return 1;
    _ = try postPaletteText(self, io, out, "renamed");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, self.workspace_registry.keyForName("renamed") == second_key, "palette rename updated the same stable workspace key", .{});

    const sidebar_switch_opened = try clickTabsElement(self, io, out, "workspaces.switch");
    workspacesCheck(out, &failures, sidebar_switch_opened and self.palette_step == .input, "the clickable sidebar Switch workspace control opened its input", .{});
    if (!sidebar_switch_opened) return 1;
    _ = try postPaletteText(self, io, out, "default");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .active = first_key }), "the sidebar switch control selected an exact workspace name", .{});

    var second_workspace_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const second_workspace_id = try workspaceSemanticId(&second_workspace_id_buffer, second_key);
    var first_workspace_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const first_workspace_id = try workspaceSemanticId(&first_workspace_id_buffer, first_key);
    workspacesCheck(out, &failures, try clickTabsElement(self, io, out, second_workspace_id) and
        self.workspace_registry.activeKey().? == second_key, "clicking the namespaced workspace row switched immediately", .{});

    const sidebar_focus_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .shift = true, .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    _ = try postNamedKey(self, io, out, .down, sidebar_focus_mods);
    _ = try postNamedKey(self, io, out, .up, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, self.workspace_registry.activeKey().? == first_key, "sidebar focus, Up and Enter switched by keyboard", .{});
    _ = try postNamedKey(self, io, out, .down, sidebar_focus_mods);
    _ = try postNamedKey(self, io, out, .down, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, self.workspace_registry.activeKey().? == second_key and
        self.activeWorkspace().tab(second_tab_id).?.paneCount() == 2 and
        self.activeWorkspace().focusedPaneId(second_tab_id) == split_pane, "Down and Enter returned to the same focused two-pane layout", .{});

    _ = try scratchpadChord(self, io, out, true);
    workspacesCheck(out, &failures, self.activePresentation().scratchpad_presentation == .ninety and
        try waitForWorkspaces(self, io, out, .{ .scratchpad_text = .{
            .key = second_key,
            .text = "WORKSPACE-SCRATCH-B:beta",
        } }), "the renamed workspace still presented its original 90 percent scratchpad", .{});
    const close_opened = try openWorkspacePaletteCommand(self, io, out, "closeworkspace", workspace_close_action);
    workspacesCheck(out, &failures, close_opened and self.pending_close_workspace == second_key and
        self.ui_tree.byId(.{ .value = "workspace-close.dialog" }) != null, "the palette opened the workspace-level close confirmation", .{});
    if (!close_opened) return 1;

    try self.drawFrame();
    var second_scratchpad_id_buffer: [workspace_semantic_capacity]u8 = undefined;
    const second_scratchpad_id = try scratchpadSemanticId(&second_scratchpad_id_buffer, second_key, "");
    workspacesCheck(out, &failures, self.ui_tree.byId(.{ .value = first_workspace_id }) != null and
        self.ui_tree.byId(.{ .value = second_workspace_id }) != null and
        self.ui_tree.byId(.{ .value = second_scratchpad_id }) != null and
        self.ui_tree.byId(.{ .value = "workspace-close.dialog" }) != null, "the semantic checkpoint contains both workspace rows, the active scratchpad and close modal", .{});
    const screenshot_pixels = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(screenshot_pixels);
    var screenshot_path_buffer: [path_capacity]u8 = undefined;
    const screenshot_path = try workspacesScreenshotPath(io, &screenshot_path_buffer);

    _ = try postNamedKey(self, io, out, .escape, .{});
    workspacesCheck(out, &failures, self.pending_close_workspace == null and self.scratchpadVisible(), "Escape cancelled palette close without hiding the scratchpad", .{});
    _ = try postScratchpadText(self, io, out, "printf 'WORKSPACE-SCRATCH-B-CLOSE:%s\\n' \"$ws_scratch\"");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .scratchpad_text = .{
        .key = second_key,
        .text = "WORKSPACE-SCRATCH-B-CLOSE:beta",
    } }), "the second scratchpad drained its final output before close", .{});
    _ = try scratchpadChord(self, io, out, true);
    _ = try postWorkspaceTerminalText(self, io, out, "closing");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .session_text = .{
        .key = second_key,
        .id = split_session,
        .text = "WORKSPACE-ECHO:closing",
    } }) and try waitForWorkspaces(self, io, out, .{ .settled = second_key }), "all terminal and scratchpad output was quiescent before teardown", .{});
    workspacesCheck(out, &failures, second_model.registeredSessionCount() == 3 and second_model.hasAttachedChild(), "the close target still owned two terminals and one scratchpad PTY", .{});

    _ = try clickTabsElement(self, io, out, "workspaces.close");
    workspacesCheck(out, &failures, self.pending_close_workspace == second_key, "the clickable sidebar Close workspace control opened confirmation", .{});
    _ = try clickTabsElement(self, io, out, "workspace-close.cancel");
    workspacesCheck(out, &failures, self.pending_close_workspace == null and self.workspace_registry.byKey(second_key) != null, "pointer cancel retained every workspace process", .{});
    _ = try clickTabsElement(self, io, out, "workspaces.close");
    _ = try clickTabsElement(self, io, out, "workspace-close.confirm");
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .removed = second_key }) and
        self.workspace_registry.count() == 1 and self.workspace_registry.activeKey().? == first_key and
        self.ui_tree.byId(.{ .value = second_workspace_id }) == null, "pointer confirmation terminated and removed all three PTY sessions, then selected the neighbour", .{});

    const first_tab_id = first_model.activeTabId() orelse return 1;
    const first_pane = first_model.focusedPaneId(first_tab_id) orelse return 1;
    var first_pane_id_buffer: [pane_semantic_capacity]u8 = undefined;
    const first_pane_id = try paneSemanticId(&first_pane_id_buffer, first_key, first_pane);
    const first_terminal_focused = try clickTabsElement(self, io, out, first_pane_id);
    _ = try postWorkspaceTerminalText(self, io, out, "after-close");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, first_terminal_focused and self.ui_tree.focusedElement() == null and
        try waitForWorkspaces(self, io, out, .{ .session_text = .{
            .key = first_key,
            .id = first_session,
            .text = "WORKSPACE-ECHO:after-close",
        } }) and (self.activeLive().child() orelse return 1).ptr == first_terminal_child.ptr, "closing the neighbour left the first terminal process and input route intact", .{});
    _ = try scratchpadChord(self, io, out, false);
    _ = try postScratchpadText(self, io, out, "printf 'WORKSPACE-SCRATCH-A-FINAL:%s\\n' \"$ws_scratch\"");
    _ = try postNamedKey(self, io, out, .enter, .{});
    workspacesCheck(out, &failures, try waitForWorkspaces(self, io, out, .{ .scratchpad_text = .{
        .key = first_key,
        .text = "WORKSPACE-SCRATCH-A-FINAL:alpha",
    } }) and (self.scratchpadLive() orelse return 1).child().?.ptr == first_scratch_child.ptr, "the surviving workspace kept its independent scratch shell state", .{});

    try writePngOffThread(self.allocator, io, screenshot_path, screenshot_pixels, self.size);
    out.print("workspaces-test: screenshot {s}\n", .{screenshot_path}) catch {};
    out.print("workspaces-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

const links_test_lexical_url = "https://lexical.test/path";
const links_test_osc_url = "https://osc-target.test/open";
/// The tracked cwd the child claims with OSC 7. It must exist locally because
/// the real editor spawn uses it, and the relative reference resolves there.
const links_test_cwd = "/tmp";
const links_test_relative_file = "./conduit-notes.txt:3";
const links_test_absolute_file = "/tmp/conduit-abs.txt";
const links_test_script =
    "stty -echo; " ++
    "printf '\x1b[2J\x1b[H\x1b]7;file://localhost" ++ links_test_cwd ++ "\x07plain " ++ links_test_lexical_url ++ "\r\n" ++
    "\x1b]8;;" ++ links_test_osc_url ++ "\x07OSC-LABEL\x1b]8;;\x07\r\n" ++
    "\x1b]8;;https://bad.\xff\x07https://masked.test\x1b]8;;\x07\r\n" ++
    "open " ++ links_test_relative_file ++ " or " ++ links_test_absolute_file ++ "\r\n" ++
    "\x1b[?1006;1000h'; " ++
    "while :; do sleep 60; done";

/// Records every editor spawn the app produced, with argv entries joined by a
/// single space; the fixture's paths contain none, so the join is exact.
const EditorSpawnTrace = struct {
    argv_bytes: [file_reference_path_max_bytes + 64]u8 = undefined,
    argv_len: usize = 0,
    argv_count: usize = 0,
    cwd_bytes: [file_reference_path_max_bytes]u8 = undefined,
    cwd_len: usize = 0,
    calls: usize = 0,

    fn argv(self: *const EditorSpawnTrace) []const u8 {
        return self.argv_bytes[0..self.argv_len];
    }

    fn cwd(self: *const EditorSpawnTrace) []const u8 {
        return self.cwd_bytes[0..self.cwd_len];
    }
};

fn recordEditorSpawn(context: ?*anyopaque, argv: []const []const u8, cwd: []const u8) void {
    const trace: *EditorSpawnTrace = @ptrCast(@alignCast(context orelse return));
    trace.calls += 1;
    trace.argv_count = argv.len;
    var writer = std.Io.Writer.fixed(&trace.argv_bytes);
    for (argv, 0..) |entry, index| {
        if (index != 0) writer.writeByte(' ') catch break;
        writer.writeAll(entry) catch break;
    }
    trace.argv_len = writer.end;
    trace.cwd_len = @min(cwd.len, trace.cwd_bytes.len);
    @memcpy(trace.cwd_bytes[0..trace.cwd_len], cwd[0..trace.cwd_len]);
}

const UrlOpenTrace = struct {
    bytes: [link.default_max_target_bytes]u8 = undefined,
    len: usize = 0,
    calls: usize = 0,

    fn value(self: *const UrlOpenTrace) []const u8 {
        return self.bytes[0..self.len];
    }
};

const TerminalLinkTestPoint = struct {
    x: f32,
    y: f32,
};

fn recordOpenedUrl(context: ?*anyopaque, _: Allocator, url: []const u8) !void {
    const trace: *UrlOpenTrace = @ptrCast(@alignCast(context orelse return error.MissingTrace));
    if (url.len > trace.bytes.len) return error.UrlTooLong;
    @memcpy(trace.bytes[0..url.len], url);
    trace.len = url.len;
    trace.calls += 1;
}

fn terminalLinkByLabel(self: *const App, label: []const u8) ?*const ui.Element {
    for (self.ui_tree.elements()) |*element| {
        if (std.mem.eql(u8, element.role, "terminal_link") and
            std.mem.eql(u8, element.label, label)) return element;
    }
    return null;
}

fn terminalLinkPoint(self: *const App, element: *const ui.Element) ?TerminalLinkTestPoint {
    if (element.bounds.isEmpty() or element.bounds.x < 0 or element.bounds.y < 0) return null;
    const scale = self.window.state.scale.factor;
    return .{
        .x = (@as(f32, @floatFromInt(element.bounds.x)) +
            @as(f32, @floatFromInt(element.bounds.width)) / 2) / scale,
        .y = (@as(f32, @floatFromInt(element.bounds.y)) +
            @as(f32, @floatFromInt(element.bounds.height)) / 2) / scale,
    };
}

fn waitForTerminalLinks(self: *App, io: Io, out: *Writer) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + 5000 * std.time.ns_per_ms;
    while (true) {
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (terminalLinkByLabel(self, links_test_lexical_url) != null and
            terminalLinkByLabel(self, "OSC-LABEL") != null and
            terminalLinkByLabel(self, links_test_relative_file) != null and
            terminalLinkByLabel(self, links_test_absolute_file) != null) return true;
        const event = self.window.pump(@min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) return false;
    }
}

/// Pump real events and worker results until the active terminal shows
/// `needle`, so an asynchronously spawned editor proves itself on screen.
fn waitForActiveTerminalText(self: *App, io: Io, out: *Writer, needle: []const u8) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + 5000 * std.time.ns_per_ms;
    while (true) {
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (self.activeLive().terminal().visibleTextContains(needle)) return true;
        const event = self.window.pump(@min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) return false;
    }
}

fn linkTestCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("links-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn postTerminalLinkClick(
    self: *App,
    io: Io,
    out: *Writer,
    point: TerminalLinkTestPoint,
    mods: platform.Mods,
) !bool {
    try self.window.postPointerButton(.{ .button = .left, .action = .press, .mods = mods, .x = point.x, .y = point.y });
    try self.window.postPointerButton(.{ .button = .left, .action = .release, .mods = mods, .x = point.x, .y = point.y });
    if (!try pumpUntil(self, io, out, .pointer_button, self_test_event_budget_ms)) return false;
    return pumpUntil(self, io, out, .pointer_button, self_test_event_budget_ms);
}

/// Drive production link composition and routing through SDL while replacing
/// only the final desktop handoff with an in-process recorder.
fn linksTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    var child_trace: ClipboardTrace = .{};
    defer child_trace.deinit(self.allocator);
    self.trace = &child_trace;
    defer self.trace = null;
    var opener_trace: UrlOpenTrace = .{};
    self.url_opener = .{ .context = &opener_trace, .open_fn = recordOpenedUrl };
    defer self.url_opener = .{};
    var editor_trace: EditorSpawnTrace = .{};
    self.editor_spawn_observer = .{ .context = &editor_trace, .observe_fn = recordEditorSpawn };
    defer self.editor_spawn_observer = .{};

    const ready = try waitForTerminalLinks(self, io, out);
    linkTestCheck(out, &failures, ready, "lexical and OSC 8 links reached the semantic tree", .{});
    if (!ready) return 1;
    linkTestCheck(out, &failures, terminalLinkByLabel(self, "https://masked.test") == null, "invalid UTF-8 OSC 8 metadata masked its URL-looking label", .{});

    const lexical = terminalLinkByLabel(self, links_test_lexical_url) orelse return 1;
    const lexical_point = terminalLinkPoint(self, lexical) orelse return 1;
    const sent_before_plain = child_trace.sent.items.len;
    const plain_delivered = try postTerminalLinkClick(self, io, out, lexical_point, .{});
    linkTestCheck(out, &failures, plain_delivered and child_trace.sent.items.len > sent_before_plain and
        opener_trace.calls == 0, "plain click remained a DEC mouse gesture and did not open the link", .{});

    const native_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true },
    };
    try self.window.postPointerMotion(.{ .mods = native_mods, .x = lexical_point.x, .y = lexical_point.y });
    const hover_delivered = try pumpUntil(self, io, out, .pointer_motion, self_test_event_budget_ms);
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const hovered = terminalLinkByLabel(self, links_test_lexical_url);
    const underline_visible = if (hovered) |element| blk: {
        const cell = self.fonts.metrics().cell;
        const col: u32 = @intCast(@divFloor(element.bounds.x, @as(i32, @intCast(cell.width_px))));
        const row: u32 = @intCast(@divFloor(element.bounds.y, @as(i32, @intCast(cell.height_px))));
        const painted = overlayCellAt(self.overlayView(), .{ .col = col, .row = row });
        break :blk painted != null and painted.?.underline != null;
    } else false;
    linkTestCheck(out, &failures, hover_delivered and underline_visible, "native-modifier hover painted a decoration-only underline", .{});

    const sent_before_lexical = child_trace.sent.items.len;
    const lexical_opened = try postTerminalLinkClick(self, io, out, lexical_point, native_mods);
    linkTestCheck(out, &failures, lexical_opened and opener_trace.calls == 1 and
        std.mem.eql(u8, opener_trace.value(), links_test_lexical_url) and
        child_trace.sent.items.len == sent_before_lexical, "modified lexical URL click opened the exact target without a DEC report", .{});

    const osc = terminalLinkByLabel(self, "OSC-LABEL") orelse return 1;
    const osc_point = terminalLinkPoint(self, osc) orelse return 1;
    const sent_before_osc = child_trace.sent.items.len;
    const osc_opened = try postTerminalLinkClick(self, io, out, osc_point, native_mods);
    linkTestCheck(out, &failures, osc_opened and opener_trace.calls == 2 and
        std.mem.eql(u8, opener_trace.value(), links_test_osc_url) and
        child_trace.sent.items.len == sent_before_osc, "OSC 8 label opened its explicit target instead of its visible text", .{});

    // File references (decision-5): stable ids, plain-click isolation, then a
    // modified click that opens the resolved path in a new tab through vi.
    const relative = terminalLinkByLabel(self, links_test_relative_file) orelse return 1;
    var relative_id_storage: [terminal_link_semantic_capacity]u8 = undefined;
    @memcpy(relative_id_storage[0..relative.id.value.len], relative.id.value);
    const relative_id = relative_id_storage[0..relative.id.value.len];
    const relative_fingerprint = std.fmt.bytesToHex(terminalLinkFingerprint(.file, "./conduit-notes.txt", 3, null), .lower);
    const absolute_fingerprint = std.fmt.bytesToHex(terminalLinkFingerprint(.file, links_test_absolute_file, null, null), .lower);
    const absolute = terminalLinkByLabel(self, links_test_absolute_file) orelse return 1;
    linkTestCheck(out, &failures, std.mem.indexOf(u8, relative_id, &relative_fingerprint) != null and
        std.mem.indexOf(u8, absolute.id.value, &absolute_fingerprint) != null and
        std.mem.indexOf(u8, relative_id, ".terminal-link.3.") != null, "file references carry domain-separated path/line/column ids", .{});
    try self.composeUi();
    const recomposed = terminalLinkByLabel(self, links_test_relative_file) orelse return 1;
    linkTestCheck(out, &failures, std.mem.eql(u8, recomposed.id.value, relative_id), "file reference ids are stable across frames", .{});

    const relative_point = terminalLinkPoint(self, recomposed) orelse return 1;
    const tabs_before = self.activeWorkspace().tabCount();
    const sent_before_file_plain = child_trace.sent.items.len;
    const file_plain_delivered = try postTerminalLinkClick(self, io, out, relative_point, .{});
    linkTestCheck(out, &failures, file_plain_delivered and child_trace.sent.items.len > sent_before_file_plain and
        editor_trace.calls == 0 and self.activeWorkspace().tabCount() == tabs_before, "plain click on a file reference stayed a DEC mouse gesture and opened no tab", .{});

    const sent_before_file = child_trace.sent.items.len;
    const file_opened = try postTerminalLinkClick(self, io, out, relative_point, native_mods);
    const expected_relative_argv = "vi +3 -- " ++ links_test_cwd ++ "/conduit-notes.txt";
    linkTestCheck(out, &failures, file_opened and editor_trace.calls == 1 and editor_trace.argv_count == 4 and
        std.mem.eql(u8, editor_trace.argv(), expected_relative_argv) and
        std.mem.eql(u8, editor_trace.cwd(), links_test_cwd) and
        child_trace.sent.items.len == sent_before_file, "modified click spawned exactly `{s}` in the tracked cwd", .{expected_relative_argv});
    // This fixture disables the sidebar to keep link geometry fixed, so the
    // sidebar row itself is proven by the scripted `terminal-file-reference`
    // scenario; here the workspace model carries the selected, labelled tab.
    const new_tab_active = self.activeWorkspace().tabCount() == tabs_before + 1 and
        self.activeWorkspace().activeTabId() != null and
        std.mem.eql(u8, self.activeWorkspace().tab(self.activeWorkspace().activeTabId().?).?.name(), "conduit-notes.txt");
    linkTestCheck(out, &failures, new_tab_active, "the new tab is selected and labelled with the file name", .{});
    // vim reports the exact path it was given in its status line, which only
    // the new active tab can show; the first tab never printed that spelling.
    const editor_drew = try waitForActiveTerminalText(self, io, out, links_test_cwd ++ "/conduit-notes.txt");
    linkTestCheck(out, &failures, editor_drew, "the real editor child drew the resolved path in the new tab", .{});

    const switched_back = switch (self.binding_profile) {
        .macos => try postKey(self, io, out, '[', .{ .super = true, .shift = true }),
        .linux_windows => try postNamedKey(self, io, out, .page_up, .{ .ctrl = true }),
    };
    const links_back = switched_back and try waitForTerminalLinks(self, io, out);
    linkTestCheck(out, &failures, links_back, "the keyboard tab chord returned to the source terminal and its links", .{});
    if (!links_back) return 1;
    const absolute_again = terminalLinkByLabel(self, links_test_absolute_file) orelse return 1;
    const absolute_point = terminalLinkPoint(self, absolute_again) orelse return 1;
    const absolute_opened = try postTerminalLinkClick(self, io, out, absolute_point, native_mods);
    const expected_absolute_argv = "vi -- " ++ links_test_absolute_file;
    linkTestCheck(out, &failures, absolute_opened and editor_trace.calls == 2 and editor_trace.argv_count == 3 and
        std.mem.eql(u8, editor_trace.argv(), expected_absolute_argv) and
        std.mem.eql(u8, editor_trace.cwd(), links_test_cwd) and
        self.activeWorkspace().tabCount() == tabs_before + 2, "an absolute reference without a line spawned exactly `{s}`", .{expected_absolute_argv});
    const absolute_drew = try waitForActiveTerminalText(self, io, out, links_test_absolute_file);
    linkTestCheck(out, &failures, absolute_drew, "the second editor tab drew its absolute path", .{});

    try self.drawFrame();
    _ = try self.capture();
    out.print("links-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

/// A deterministic scrollback fixture: mixed-case visible matches, one match
/// older than the viewport, and a child that remains attached while search is
/// driven through SDL.
const search_test_script =
    "stty -echo; " ++
    "i=0; while [ \"$i\" -lt 140 ]; do printf 'pagehit-%03d\\r\\n' \"$i\"; i=$((i+1)); done; " ++
    "printf 'Needle OLD\\r\\n'; " ++
    "i=0; while [ \"$i\" -lt 48 ]; do printf 'fill-%02d\\r\\n' \"$i\"; i=$((i+1)); done; " ++
    "printf 'Needle NEW\\r\\nneedle exact\\r\\nSEARCH-READY\\r\\n'; " ++
    "while IFS= read -r line; do " ++
    "if [ \"$line\" = stream ]; then " ++
    "i=0; while [ \"$i\" -lt 512 ]; do printf 'noise-%04d\\r\\n' \"$i\"; i=$((i+1)); done; " ++
    "printf 'needle OUTPUT\\r\\n'; " ++
    "elif [ \"$line\" = regexstream ]; then " ++
    "i=0; while [ \"$i\" -lt 512 ]; do printf 'regex-noise-%03d\\r\\n' \"$i\"; i=$((i+1)); done; " ++
    "printf 'pagehit-140\\r\\n'; " ++
    "else printf 'SEARCH-ECHO:%s\\r\\n' \"$line\"; fi; done";

const search_test_budget_ms: i64 = 7500;

const SearchWait = union(enum) {
    terminal_text: []const u8,
    complete: usize,
    element: []const u8,
    active_candidate: usize,
    page_scan,
    settled,
};

fn searchWaitMet(self: *App, condition: SearchWait) bool {
    return switch (condition) {
        .terminal_text => |text| self.activeLive().terminal().visibleTextContains(text),
        .complete => |minimum| self.search_visible and self.search_failure == null and
            searchVisibleProgress(self.search_progress, self.search_page_scan != null) == .complete and
            self.search_match_count >= minimum,
        .element => |id| self.ui_tree.byId(.{ .value = id }) != null,
        .active_candidate => |candidate| self.search_page_scan == null and
            self.search_match_count != 0 and
            self.search_pages[self.search_page_slot][self.search_active_index].candidate_index == candidate,
        .page_scan => self.search_engine_live and self.search_progress == .complete and
            self.search_page_scan != null,
        .settled => self.search_engine_live and self.search_page_scan == null,
    };
}

fn waitForSearch(self: *App, io: Io, out: *Writer, condition: SearchWait) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + search_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        if (searchWaitMet(self, condition)) return true;
        const event = self.window.pump(if (self.searchNeedsWork())
            0
        else
            @min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) return searchWaitMet(self, condition);
    }
}

fn searchCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("search-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn searchHighlightCount(self: *const App) usize {
    var count: usize = 0;
    for (self.ui_tree.elements()) |element| {
        if (std.mem.eql(u8, element.role, "search_match")) count += 1;
    }
    return count;
}

fn activeSearchHighlightVisible(self: *const App) bool {
    for (self.ui_tree.elements()) |element| {
        if (std.mem.eql(u8, element.role, "search_match") and element.state.selected) return true;
    }
    return false;
}

fn searchStatusContains(self: *const App, text: []const u8) bool {
    const status = self.ui_tree.byId(.{ .value = "search.status" }) orelse return false;
    return std.mem.indexOf(u8, status.label, text) != null;
}

fn clickSearchElement(self: *App, io: Io, out: *Writer, id: []const u8) !bool {
    const element = self.ui_tree.byId(.{ .value = id }) orelse return false;
    const point = elementCenter(element, self.window.state.scale);
    if (!try postButton(self, io, out, .{
        .button = .left,
        .action = .press,
        .x = point.x,
        .y = point.y,
    })) return false;
    return postButton(self, io, out, .{
        .button = .left,
        .action = .release,
        .x = point.x,
        .y = point.y,
    });
}

fn firstVisibleSearchMatchId(self: *const App) ?[]const u8 {
    for (self.ui_tree.elements()) |element| {
        if (std.mem.eql(u8, element.role, "search_match")) return element.id.value;
    }
    return null;
}

/// Exercise TASK-36 through the production action registry, semantic tree,
/// SDL keyboard/text path, full terminal scrollback and shared renderer.
fn searchTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    try self.drawFrame();
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .terminal_text = "SEARCH-READY" }), "the real PTY produced the visible fixture", .{});

    const open_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true, .shift = true },
    };
    searchCheck(out, &failures, try postKey(self, io, out, 'f', open_mods) and
        try waitForSearch(self, io, out, .{ .element = "search.query" }), "the search keybinding opened the semantic Input", .{});
    searchCheck(out, &failures, self.ui_tree.focusedElement() != null and
        std.mem.eql(u8, self.ui_tree.focusedElement().?.id.value, "search.query"), "the inline query owns text focus", .{});

    try self.window.postTextInput("needle");
    searchCheck(out, &failures, try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms), "query text travelled through SDL", .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = 3 }) and
        self.search_match_count == 3, "incremental search found visible and retained off-screen matches", .{});
    searchCheck(out, &failures, searchHighlightCount(self) != 0 and activeSearchHighlightVisible(self), "visible matches and the active match have semantic decorations", .{});

    _ = try postNamedKey(self, io, out, .enter, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    const old_offset = self.presentedLive().terminal().viewport().offset;
    searchCheck(out, &failures, self.search_active_index == 2 and old_offset != 0 and
        activeSearchHighlightVisible(self), "Next wrapped through ordered results and followed the off-screen match", .{});
    _ = try postNamedKey(self, io, out, .enter, .{ .shift = true });
    searchCheck(out, &failures, self.search_active_index == 1 and
        self.presentedLive().terminal().viewport().offset < old_offset, "Shift+Enter selected the previous match and followed it toward newer output", .{});

    _ = try postKey(self, io, out, 'c', .{ .alt = true });
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = 1 }) and
        self.search_case == .sensitive and self.search_match_count == 1, "the case-toggle keybinding reran an exact-case search", .{});

    const select_all_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true },
    };
    _ = try postKey(self, io, out, 'a', select_all_mods);
    try self.window.postTextInput("Needle (OLD|NEW)");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postKey(self, io, out, 'r', .{ .alt = true });
    searchCheck(out, &failures, try waitForSearch(self, io, out, .page_scan) and
        searchStatusContains(self, "searching"), "regex page materialization remains visibly running after engine preparation", .{});
    const partial_active = self.search_active_index;
    _ = try postNamedKey(self, io, out, .enter, .{});
    searchCheck(out, &failures, self.search_page_scan != null and
        self.search_active_index == partial_active, "navigation stays gated until the regex page reaches a real boundary", .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = 2 }) and
        self.search_mode == .regex and self.search_match_count == 2, "the regex keybinding matched alternation across retained scrollback", .{});

    _ = try postKey(self, io, out, 'a', select_all_mods);
    try self.window.postTextInput("(");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    searchCheck(out, &failures, self.search_mode == .regex and
        !self.search_engine_live and self.search_match_count == 0 and
        std.mem.eql(u8, self.search_failure orelse "", "invalid regex"), "a malformed pattern is visible and non-fatal", .{});

    _ = try postKey(self, io, out, 'a', select_all_mods);
    try self.window.postTextInput("needle");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = 1 }), "a valid regex recovered after the malformed pattern", .{});

    _ = try postKey(self, io, out, 'a', select_all_mods);
    try self.window.postTextInput("pagehit");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = search_match_capacity }) and
        self.search_mode == .regex and self.search_match_count == search_match_capacity, "regex retained a bounded first page from more than 128 matches", .{});
    const regex_newest_row = self.search_pages[self.search_page_slot][self.search_active_index].match.first.row;
    _ = try postNamedKey(self, io, out, .enter, .{ .shift = true });
    const regex_wrapped_oldest = try waitForSearch(self, io, out, .settled) and
        self.search_pages[self.search_page_slot][self.search_active_index].match.first.row < regex_newest_row;
    searchCheck(out, &failures, regex_wrapped_oldest, "regex Previous wrapped from the newest match to the oldest", .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .settled) and
        self.search_pages[self.search_page_slot][self.search_active_index].match.first.row == regex_newest_row, "regex Next wrapped from the oldest match to the newest", .{});
    for (0..search_match_capacity) |_| _ = try postNamedKey(self, io, out, .enter, .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .settled) and
        self.search_match_count < search_match_capacity and
        self.search_pages[self.search_page_slot][self.search_active_index].match.first.row < regex_newest_row, "regex Next crossed the bounded page boundary without rescanning the prefix", .{});
    const regex_second_page_row = self.search_pages[self.search_page_slot][self.search_active_index].match.first.row;
    _ = try postNamedKey(self, io, out, .enter, .{ .shift = true });
    searchCheck(out, &failures, try waitForSearch(self, io, out, .settled) and
        self.search_match_count == search_match_capacity and
        self.search_pages[self.search_page_slot][self.search_active_index].match.first.row > regex_second_page_row, "regex Previous crossed back from the adjacent page in canonical order", .{});

    searchCheck(out, &failures, try clickSearchElement(self, io, out, "search.close") and
        !self.search_visible, "regex search closed before driving new PTY output", .{});
    try self.window.postTextInput("regexstream");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    const regex_resync_before = self.search_resync_count;
    _ = try postKey(self, io, out, 'f', open_mods);
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = search_match_capacity }) and
        self.search_mode == .regex and self.search_resync_count > regex_resync_before, "real PTY output invalidated and resynchronized the active regex query", .{});

    const original_size = self.window.state.logical;
    const logical_cell = platform.LogicalSize{
        .width = logicalPixels(self.fonts.metrics().cell.width_px, self.window.state.scale),
        .height = logicalPixels(self.fonts.metrics().cell.height_px, self.window.state.scale),
    };
    const compact_size = platform.LogicalSize{
        .width = logical_cell.width *| 20,
        .height = logical_cell.height *| 3,
    };
    const resize_resync_before = self.search_resync_count;
    try self.window.setLogicalSize(compact_size);
    const compact_resized = try pumpUntil(self, io, out, .{ .resize = compact_size }, self_test_event_budget_ms);
    const compact_ready = compact_resized and
        try waitForSearch(self, io, out, .{ .complete = search_match_capacity });
    const compact_layout = self.searchBarLayout();
    const compact_query = self.ui_tree.byId(.{ .value = "search.query" });
    searchCheck(out, &failures, compact_ready and self.search_resync_count > resize_resync_before and
        compact_layout != null and !compact_layout.?.bordered and
        compact_layout.?.query.width != 0 and compact_layout.?.query.height != 0 and
        compact_query != null and !compact_query.?.bounds.isEmpty(), "regex resize invalidation kept a usable compact semantic Input on a sub-42x4 canvas", .{});
    try self.window.setLogicalSize(original_size);
    const restored_size = try pumpUntil(self, io, out, .{ .resize = original_size }, self_test_event_budget_ms);
    searchCheck(out, &failures, restored_size and
        try waitForSearch(self, io, out, .{ .complete = search_match_capacity }), "the regex query resynchronized again after restoring the window", .{});

    _ = try postKey(self, io, out, 'a', select_all_mods);
    try self.window.postTextInput("needle");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    // `needle OUTPUT` is only printed by the later stream step, so a
    // case-sensitive query sees exactly `needle exact` at this point.
    searchCheck(out, &failures, self.search_mode == .regex and self.search_case == .sensitive and
        try waitForSearch(self, io, out, .{ .complete = 1 }), "regex search remained usable after PTY output and resize invalidation", .{});
    searchCheck(out, &failures, try clickSearchElement(self, io, out, "search.regex") and
        self.search_mode == .literal and try waitForSearch(self, io, out, .{ .complete = 1 }), "the clickable regex control dispatched the same toggle", .{});
    searchCheck(out, &failures, try clickSearchElement(self, io, out, "search.case") and
        self.search_case == .ascii_insensitive and try waitForSearch(self, io, out, .{ .complete = 3 }), "the clickable case control reran ASCII-insensitive search", .{});

    // Close by mouse, produce output through real SDL keyboard input and the
    // real PTY peer, then reopen before drawing. The first draw drains the
    // multi-chunk response while a search generation is live, proving the
    // invalidation/resync path without direct terminal.feed or sleeps.
    searchCheck(out, &failures, try clickSearchElement(self, io, out, "search.close") and
        !self.search_visible, "the clickable close control dismissed search", .{});
    try self.window.postTextInput("stream");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    const resync_before = self.search_resync_count;
    _ = try postKey(self, io, out, 'f', open_mods);
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = 4 }) and
        self.search_match_count == 4 and self.search_resync_count > resync_before, "real user input drove PTY output through bounded generation resync", .{});

    searchCheck(out, &failures, try clickSearchElement(self, io, out, "search.next") and
        self.search_active_index == 1, "the clickable next control dispatched navigation", .{});
    searchCheck(out, &failures, try clickSearchElement(self, io, out, "search.previous") and
        self.search_active_index == 0, "the clickable previous control dispatched navigation", .{});
    _ = try clickSearchElement(self, io, out, "search.next");
    const match_id = firstVisibleSearchMatchId(self);
    const match_index = if (match_id) |id| App.searchMatchSemanticIndex(id) else null;
    const activated = if (match_id) |id| try clickSearchElement(self, io, out, id) else false;
    const activated_exact_match = if (match_index) |index|
        activated and self.search_active_index == index
    else
        false;
    searchCheck(out, &failures, activated_exact_match, "a clickable visible highlight activated its exact match", .{});

    _ = try postNamedKey(self, io, out, .escape, .{});
    searchCheck(out, &failures, !self.search_visible, "Escape closed search without reaching the terminal", .{});
    _ = try paletteChord(self, io, out);
    try self.window.postTextInput("terminalsearch");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .element = "search.dialog" }) and
        self.search_visible, "the command palette opened the same named search action", .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = 4 }) and
        self.search_case == .ascii_insensitive and self.search_match_count == 4, "the palette-opened search retained and reran its query", .{});
    _ = try postKey(self, io, out, 'a', select_all_mods);
    try self.window.postTextInput("pagehit");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .complete = search_match_capacity }) and
        self.search_match_count == search_match_capacity, "a bounded first page retained 128 of more than 128 matches", .{});

    _ = try postNamedKey(self, io, out, .enter, .{ .shift = true });
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .active_candidate = 140 }), "Previous from the newest match wrapped to the oldest match", .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .active_candidate = 0 }), "Next from the oldest match wrapped to the newest match", .{});
    for (0..search_match_capacity) |_| _ = try postNamedKey(self, io, out, .enter, .{});
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .active_candidate = search_match_capacity }), "Next crossed the bounded page boundary without rescanning the prefix", .{});
    _ = try postNamedKey(self, io, out, .enter, .{ .shift = true });
    searchCheck(out, &failures, try waitForSearch(self, io, out, .{ .active_candidate = search_match_capacity - 1 }), "Previous crossed back from the adjacent page in canonical order", .{});

    while (self.search_active_index + 1 < self.search_match_count) {
        _ = try postNamedKey(self, io, out, .enter, .{});
    }
    try self.drawFrame();
    _ = try self.capture();
    searchCheck(out, &failures, self.presentedLive().terminal().viewport().offset != 0 and
        self.ui_tree.byId(.{ .value = "search.dialog" }) != null and
        activeSearchHighlightVisible(self), "the captured frame is ready with the bar and active off-screen match", .{});

    out.print("search-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

const menu_test_url = "https://menu.test/open";
/// A deterministic real PTY peer for `--menu-test`: a visible URL for the
/// `open link` row, a readiness marker, then a line reader that enables and
/// disables SGR mouse reporting on request so DEC capture is the program's
/// own choice rather than a mode set by hand.
const menu_test_script =
    "stty -echo; " ++
    "printf '\x1b[2J\x1b[Hmenu " ++ menu_test_url ++ "\r\nMENU-READY\r\n'; " ++
    "while IFS= read -r line; do " ++
    "if [ \"$line\" = capture ]; then printf '\x1b[?1006;1000hCAPTURED\r\n'; " ++
    "else printf 'MENU-ECHO:%s\r\n' \"$line\"; fi; done";

const menu_test_budget_ms: i64 = 5000;

const MenuWait = union(enum) {
    terminal_text: []const u8,
    element: []const u8,
    element_absent: []const u8,
    link: []const u8,
    sent_contains: []const u8,
    mouse_tracking: term.MouseTracking,
};

fn menuWaitMet(self: *App, condition: MenuWait) bool {
    return switch (condition) {
        .terminal_text => |text| self.activeLive().terminal().visibleTextContains(text),
        .element => |id| self.ui_tree.byId(.{ .value = id }) != null,
        .element_absent => |id| self.ui_tree.byId(.{ .value = id }) == null,
        .link => |label| terminalLinkByLabel(self, label) != null,
        .sent_contains => |bytes| if (self.trace) |trace| std.mem.indexOf(u8, trace.sent.items, bytes) != null else false,
        .mouse_tracking => |mode| self.presentedLive().terminal().mouseTracking() == mode,
    };
}

fn waitForMenu(self: *App, io: Io, out: *Writer, condition: MenuWait) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + menu_test_budget_ms * std.time.ns_per_ms;
    while (true) {
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        if (menuWaitMet(self, condition)) return true;
        const event = self.window.pump(@min(self.waitBudget(io, deadline), 50));
        if (event) |one| {
            describeEvent(out, one) catch {};
            if (!try self.handle(one)) return false;
        }
        if (self.poll()) self.scheduler.invalidate();
        if (Io.Clock.real.now(io).nanoseconds >= deadline) {
            if (self.scheduler.shouldDraw()) try self.drawFrame();
            return menuWaitMet(self, condition);
        }
    }
}

fn menuCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("menu-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn postRightClick(self: *App, io: Io, out: *Writer, x: f32, y: f32, mods: platform.Mods) !bool {
    if (!try postButton(self, io, out, .{ .button = .right, .action = .press, .mods = mods, .x = x, .y = y })) return false;
    return postButton(self, io, out, .{ .button = .right, .action = .release, .mods = mods, .x = x, .y = y });
}

fn postLeftClick(self: *App, io: Io, out: *Writer, x: f32, y: f32) !bool {
    if (!try postButton(self, io, out, .{ .button = .left, .action = .press, .x = x, .y = y })) return false;
    return postButton(self, io, out, .{ .button = .left, .action = .release, .x = x, .y = y });
}

fn focusedMenuRow(self: *const App) []const u8 {
    const focused = self.ui_tree.focusedElement() orelse return "";
    return focused.id.value;
}

/// The ids the menu shows, in row order, as one comparable string.
fn menuRowIds(self: *const App, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    for (self.ui_tree.elements()) |element| {
        if (!std.mem.eql(u8, element.role, "menu_item")) continue;
        writer.writeAll(element.id.value) catch break;
        writer.writeByte(' ') catch break;
    }
    return buffer[0..writer.end];
}

/// Exercise TASK-35 through the production pointer and key routing: the menu
/// opens at the pointer with context-appropriate rows, is keyboard navigable
/// and modal, its rows dispatch completed actions, the paste alternative
/// replaces it, and DEC mouse capture keeps a plain right click the program's.
fn menuTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    var child_trace: ClipboardTrace = .{};
    defer child_trace.deinit(self.allocator);
    self.trace = &child_trace;
    defer self.trace = null;
    var opener_trace: UrlOpenTrace = .{};
    self.url_opener = .{ .context = &opener_trace, .open_fn = recordOpenedUrl };
    defer self.url_opener = .{};

    try self.drawFrame();
    menuCheck(out, &failures, try waitForMenu(self, io, out, .{ .terminal_text = "MENU-READY" }) and
        try waitForMenu(self, io, out, .{ .link = menu_test_url }), "the real PTY produced the fixture and its link reached the semantic tree", .{});
    menuCheck(out, &failures, self.right_click == .menu, "the right-click setting resolved to the built-in menu default", .{});

    // 1. Right click on a plain cell: the menu at that cell, no copy or link.
    const anchor_col: u16 = 10;
    const anchor_row: u16 = 5;
    const anchor = cellPosition(self, anchor_col, anchor_row);
    var sent_mark = child_trace.sent.items.len;
    menuCheck(out, &failures, try postRightClick(self, io, out, anchor.x, anchor.y, .{}) and
        try waitForMenu(self, io, out, .{ .element = "context-menu" }), "a right click over the focused terminal opened the context menu", .{});
    var rows_buffer: [256]u8 = undefined;
    menuCheck(out, &failures, std.mem.eql(u8, menuRowIds(self, &rows_buffer), "context-menu.paste context-menu.split-right context-menu.split-down context-menu.search "), "without a selection or link the rows are paste, split right, split down and search", .{});
    const menu_element = self.ui_tree.byId(.{ .value = "context-menu" });
    const cell = self.fonts.metrics().cell;
    menuCheck(out, &failures, menu_element != null and
        menu_element.?.bounds.x == @as(i32, @intCast(@as(u32, anchor_col) * cell.width_px)) and
        menu_element.?.bounds.y == @as(i32, @intCast(@as(u32, anchor_row) * cell.height_px)), "the panel's top-left corner sits on the pointer cell", .{});
    menuCheck(out, &failures, std.mem.eql(u8, focusedMenuRow(self), "context-menu.paste"), "the first row is highlighted when the menu opens", .{});
    menuCheck(out, &failures, child_trace.sent.items.len == sent_mark, "the opening right click sent the program nothing", .{});

    // 2. Keyboard navigation, modal swallowing, Enter on search.
    _ = try postNamedKey(self, io, out, .down, .{});
    const after_down = std.mem.eql(u8, focusedMenuRow(self), "context-menu.split-right");
    _ = try postNamedKey(self, io, out, .down, .{});
    _ = try postNamedKey(self, io, out, .down, .{});
    const after_three = std.mem.eql(u8, focusedMenuRow(self), "context-menu.search");
    _ = try postNamedKey(self, io, out, .down, .{});
    const wrapped = std.mem.eql(u8, focusedMenuRow(self), "context-menu.paste");
    _ = try postNamedKey(self, io, out, .up, .{});
    const wrapped_back = std.mem.eql(u8, focusedMenuRow(self), "context-menu.search");
    _ = try postNamedKey(self, io, out, .tab, .{ .shift = true });
    const shift_tab = std.mem.eql(u8, focusedMenuRow(self), "context-menu.split-down");
    _ = try postNamedKey(self, io, out, .tab, .{});
    const tab = std.mem.eql(u8, focusedMenuRow(self), "context-menu.search");
    menuCheck(out, &failures, after_down and after_three and wrapped and wrapped_back and shift_tab and tab, "Down, Up, Tab and Shift+Tab move the highlighted row with wrap-around", .{});
    _ = try postKey(self, io, out, 'x', .{});
    menuCheck(out, &failures, child_trace.sent.items.len == sent_mark and self.contextMenuVisible(), "an unrelated key is swallowed by the modal menu instead of reaching the terminal", .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    menuCheck(out, &failures, try waitForMenu(self, io, out, .{ .element = "search.query" }) and
        self.search_visible and !self.contextMenuVisible(), "Enter on the search row dispatched search.open and closed the menu", .{});
    menuCheck(out, &failures, child_trace.sent.items.len == sent_mark, "the navigation keys and Enter sent the program nothing", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    menuCheck(out, &failures, !self.search_visible, "Escape closed the search the menu opened", .{});

    // 3. Escape closes the menu; an outside click closes it without a tail.
    menuCheck(out, &failures, try postRightClick(self, io, out, anchor.x, anchor.y, .{}) and
        try waitForMenu(self, io, out, .{ .element = "context-menu" }), "the menu reopened for the Escape check", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    menuCheck(out, &failures, !self.contextMenuVisible() and self.ui_tree.byId(.{ .value = "context-menu" }) == null, "Escape closed the menu", .{});
    menuCheck(out, &failures, try postRightClick(self, io, out, anchor.x, anchor.y, .{}) and
        try waitForMenu(self, io, out, .{ .element = "context-menu" }), "the menu reopened for the outside-click check", .{});
    const outside = cellPosition(self, 2, 1);
    _ = try postLeftClick(self, io, out, outside.x, outside.y);
    menuCheck(out, &failures, !self.contextMenuVisible() and child_trace.sent.items.len == sent_mark and
        !self.presentedLive().terminal().hasSelection(), "a click outside closed the menu and neither press nor release reached the terminal", .{});

    // 4. A selection adds the copy row, and the row copies the selection.
    menuCheck(out, &failures, try dragAcross(self, io, out, 0, 0, 4) and self.presentedLive().terminal().hasSelection(), "a real drag selected the first word", .{});
    menuCheck(out, &failures, try postRightClick(self, io, out, anchor.x, anchor.y, .{}) and
        try waitForMenu(self, io, out, .{ .element = "context-menu.copy" }), "with a selection the menu offers a copy row", .{});
    menuCheck(out, &failures, std.mem.eql(u8, focusedMenuRow(self), "context-menu.copy") and
        self.ui_tree.byId(.{ .value = "context-menu.open-link" }) == null, "copy is the first highlighted row and no link row appears off a link", .{});
    const dispatches_before_copy = self.action_dispatch_count;
    menuCheck(out, &failures, try clickSearchElement(self, io, out, "context-menu.copy") and !self.contextMenuVisible() and
        self.action_dispatch_count == dispatches_before_copy + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", clipboard_copy_action), "clicking the copy row dispatched clipboard.copy once and closed the menu", .{});
    const copied = try clipboardNow(self);
    defer self.allocator.free(copied);
    menuCheck(out, &failures, std.mem.eql(u8, copied, "menu"), "the clipboard holds the selected word", .{});
    _ = try postLeftClick(self, io, out, outside.x, outside.y);
    menuCheck(out, &failures, !self.presentedLive().terminal().hasSelection(), "a plain click cleared the selection again", .{});

    // 5. Over a link the menu offers open link, dispatching the ctrl-click seam.
    const link_element = terminalLinkByLabel(self, menu_test_url) orelse return 1;
    const link_point = terminalLinkPoint(self, link_element) orelse return 1;
    menuCheck(out, &failures, try postRightClick(self, io, out, link_point.x, link_point.y, .{}) and
        try waitForMenu(self, io, out, .{ .element = "context-menu.open-link" }), "over a link the menu offers an open link row", .{});
    menuCheck(out, &failures, std.mem.eql(u8, menuRowIds(self, &rows_buffer), "context-menu.paste context-menu.open-link context-menu.split-right context-menu.split-down context-menu.search "), "the link row sits between paste and the split rows", .{});
    _ = try postNamedKey(self, io, out, .down, .{});
    _ = try postNamedKey(self, io, out, .enter, .{});
    menuCheck(out, &failures, !self.contextMenuVisible() and opener_trace.calls == 1 and
        std.mem.eql(u8, opener_trace.value(), menu_test_url), "Enter on open link opened the exact URL through the opener seam", .{});
    const native_mods: platform.Mods = switch (self.binding_profile) {
        .macos => .{ .super = true },
        .linux_windows => .{ .ctrl = true },
    };
    _ = try postTerminalLinkClick(self, io, out, link_point, native_mods);
    menuCheck(out, &failures, opener_trace.calls == 2 and std.mem.eql(u8, opener_trace.value(), menu_test_url), "a modified click on the same link reaches the same seam with the same target", .{});

    // 6. The keyboard chord opens the menu at the terminal cursor.
    const cursor = self.presentedLive().terminal().cursor().position orelse term.Position{ .col = 0, .row = 0 };
    _ = try postNamedKey(self, io, out, .f10, .{ .shift = true });
    const keyboard_menu = self.ui_tree.byId(.{ .value = "context-menu" });
    menuCheck(out, &failures, self.contextMenuVisible() and keyboard_menu != null and
        keyboard_menu.?.bounds.x == @as(i32, @intCast(@as(u32, cursor.col) * cell.width_px)) and
        keyboard_menu.?.bounds.y == @as(i32, @intCast(@as(u32, cursor.row) * cell.height_px)), "Shift+F10 opened the menu at the terminal cursor cell", .{});
    menuCheck(out, &failures, paletteContainsDefinition(self, terminal_context_menu_action), "the context menu action is a palette-visible command", .{});
    _ = try postNamedKey(self, io, out, .escape, .{});
    menuCheck(out, &failures, !self.contextMenuVisible() and child_trace.sent.items.len == sent_mark, "Escape closed the keyboard-opened menu without terminal leakage", .{});

    // 7. The session layer can make a right click paste instead. The flag
    //    sets this at startup; the check flips the resolved value in place.
    try platform.setClipboardText(self.allocator, "menu-paste");
    self.right_click = .paste;
    const dispatches_before_paste = self.action_dispatch_count;
    menuCheck(out, &failures, try postRightClick(self, io, out, anchor.x, anchor.y, .{}) and
        try waitForMenu(self, io, out, .{ .sent_contains = "menu-paste" }) and !self.contextMenuVisible() and
        self.action_dispatch_count == dispatches_before_paste + 1 and
        std.mem.eql(u8, self.last_dispatched_action orelse "", clipboard_paste_action), "with mouse.right_click=paste a right click pasted the clipboard through clipboard.paste", .{});
    menuCheck(out, &failures, std.mem.eql(u8, child_trace.sent.items[sent_mark..], "menu-paste"), "the paste is exactly the clipboard text, unbracketed because the program did not ask", .{});
    self.right_click = .menu;
    // Finish the pasted line so the program's line reader echoes it back and
    // starts the next request from an empty line.
    _ = try postNamedKey(self, io, out, .enter, .{});
    menuCheck(out, &failures, try waitForMenu(self, io, out, .{ .terminal_text = "MENU-ECHO:menu-paste" }), "the program read the pasted text as its input line", .{});
    sent_mark = child_trace.sent.items.len;

    // 8. DEC mouse capture: plain right click is the program's, Shift's is ours.
    try self.window.postTextInput("capture");
    _ = try pumpUntil(self, io, out, .text_input, self_test_event_budget_ms);
    _ = try postNamedKey(self, io, out, .enter, .{});
    menuCheck(out, &failures, try waitForMenu(self, io, out, .{ .terminal_text = "CAPTURED" }) and
        try waitForMenu(self, io, out, .{ .mouse_tracking = .press }), "the program enabled SGR mouse reporting on request", .{});
    sent_mark = child_trace.sent.items.len;
    _ = try postRightClick(self, io, out, anchor.x, anchor.y, .{});
    var report: [64]u8 = undefined;
    const want_report = try std.fmt.bufPrint(&report, "\x1b[<2;{d};{d}M\x1b[<2;{d};{d}m", .{ anchor_col + 1, anchor_row + 1, anchor_col + 1, anchor_row + 1 });
    menuCheck(out, &failures, !self.contextMenuVisible() and
        std.mem.eql(u8, child_trace.sent.items[sent_mark..], want_report), "under mouse capture a plain right click became the program's SGR press and release", .{});
    sent_mark = child_trace.sent.items.len;
    menuCheck(out, &failures, try postRightClick(self, io, out, anchor.x, anchor.y, .{ .shift = true }) and
        try waitForMenu(self, io, out, .{ .element = "context-menu" }) and child_trace.sent.items.len == sent_mark, "Shift+right click bypassed the capture and opened the menu without a report", .{});
    _ = try postLeftClick(self, io, out, outside.x, outside.y);
    menuCheck(out, &failures, !self.contextMenuVisible() and child_trace.sent.items.len == sent_mark, "the closing outside click was not reported to the capturing program", .{});

    // 9. Leave the fullest menu on screen for the captured frame. The program
    //    still owns the mouse, so the selection drag holds Shift too.
    const drag_from = cellPosition(self, 0, 0);
    const drag_to = cellPosition(self, 4, 0);
    const shift: platform.Mods = .{ .shift = true };
    const shift_drag = try postButton(self, io, out, .{ .button = .left, .action = .press, .mods = shift, .x = drag_from.x, .y = drag_from.y }) and
        try postMotion(self, io, out, .{ .buttons = .{ .left = true }, .mods = shift, .x = drag_to.x, .y = drag_to.y }) and
        try postButton(self, io, out, .{ .button = .left, .action = .release, .mods = shift, .x = drag_to.x, .y = drag_to.y });
    menuCheck(out, &failures, shift_drag and self.presentedLive().terminal().hasSelection() and
        child_trace.sent.items.len == sent_mark, "a Shift drag selected under capture without a report", .{});
    menuCheck(out, &failures, try postRightClick(self, io, out, link_point.x, link_point.y, .{ .shift = true }) and
        try waitForMenu(self, io, out, .{ .element = "context-menu.copy" }) and
        self.ui_tree.byId(.{ .value = "context-menu.open-link" }) != null, "the final menu shows every row", .{});
    try self.drawFrame();
    _ = try self.capture();

    out.print("menu-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

const ime_test_commit: [:0]const u8 = "日本語";
const ime_test_preedit: [:0]const u8 = "にほん";
const ime_test_wide: [:0]const u8 = "日本";
const ime_test_screenshot_preedit: [:0]const u8 = "compose";
const ime_test_ready = "IME-READY\r\n";
const ime_test_done = "IME-DONE\r\n";
const ime_test_budget_ms: i64 = 5000;

/// A fixed real PTY peer for `--ime-test`. It announces readiness, reads the
/// exact commit length in raw mode, echoes those bytes as hex, then stays
/// blocked on input so the idle-loop measurement has a live child.
const ime_test_script = std.fmt.comptimePrint(
    "stty raw -echo; " ++
        "printf '\\033[48;2;17;31;47m\\033[2J\\033[?25lIME-READY\\r\\n'; " ++
        "dd bs=1 count={d} 2>/dev/null | od -An -tx1 -v | tr -d '\\n'; " ++
        "printf '\\r\\nIME-DONE\\r\\n'; " ++
        "while :; do dd bs=1 count=1 2>/dev/null >/dev/null; done",
    .{ime_test_commit.len},
);

fn imeCheck(out: *Writer, failures: *usize, ok: bool, comptime format: []const u8, args: anytype) void {
    out.print("ime-test: {s} " ++ format ++ "\n", .{if (ok) "ok  " else "FAIL"} ++ args) catch {};
    if (!ok) failures.* += 1;
}

fn positionTerminalCursor(self: *App, col: u16, row: u16) !void {
    var control: [32]u8 = undefined;
    const move = try std.fmt.bufPrint(&control, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
    self.activeLive().terminal().feed(move);
    self.invalidateUi();
}

/// Drive inline composition through SDL's real queue and commit through a
/// real PTY. The fixture uses the same renderer, event handler and single
/// child-write site as an ordinary window.
fn imeTest(self: *App, io: Io, out: *Writer) !u8 {
    var failures: usize = 0;
    var trace: ClipboardTrace = .{};
    defer trace.deinit(self.allocator);
    self.trace = &trace;
    defer self.trace = null;

    if (self.activePresentation().load) |job| {
        if (job.thread) |thread| thread.join();
        job.thread = null;
    }
    _ = self.pollLoad();
    if (self.activeLive().child() == null) {
        imeCheck(out, &failures, false, "the child did not start", .{});
        return 1;
    }
    imeCheck(out, &failures, try waitForChildText(self, io, ime_test_ready), "the raw PTY child announced readiness", .{});
    try settle(self, out);

    const grid = self.activeLive().terminal().gridSize();
    const initial_col: u16 = @min(4, grid.cols - 1);
    const initial_row: u16 = @min(4, grid.rows - 1);
    try positionTerminalCursor(self, initial_col, initial_row);
    try self.drawFrame();
    const baseline = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(baseline);

    const sent_before_preedit = trace.sent.items.len;
    try self.window.postTextEditing(ime_test_preedit, 3, 3);
    imeCheck(out, &failures, try pumpUntil(self, io, out, .text_editing, ime_test_budget_ms), "SDL delivered the text-editing event", .{});
    imeCheck(out, &failures, trace.sent.items.len == sent_before_preedit, "the preedit wrote zero bytes to the child", .{});
    try self.drawFrame();
    const composed = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(composed);
    const initial_position = render.OverlayPosition{ .col = initial_col, .row = initial_row };
    const initial_rect = uiTestCellRect(self, initial_position);
    const projected = self.ui_canvas.view(&default_palette);
    const first = overlayCellAt(projected, initial_position);
    const preedit_element = self.ui_tree.byId(.{ .value = "ime.preedit" });
    const accent = ui.resolveRole(&default_palette, .accent);
    imeCheck(out, &failures, preedit_element != null and
        std.mem.eql(u8, preedit_element.?.role, "preedit") and
        std.mem.eql(u8, preedit_element.?.label, ime_test_preedit) and
        first != null and first.?.underline != null and
        sameColor(first.?.underline.?, accent), "the semantic preedit uses the accent underline at the terminal cursor", .{});
    imeCheck(out, &failures, countDifferingPixelsInRect(baseline, composed, self.size, initial_rect) > 0, "the styled preedit changed framebuffer pixels at the real cursor", .{});

    const logical_cell = platform.LogicalSize{
        .width = logicalPixels(self.fonts.metrics().cell.width_px, self.window.state.scale),
        .height = logicalPixels(self.fonts.metrics().cell.height_px, self.window.state.scale),
    };
    const area = self.window.textInputArea();
    const expected_caret_cells = preeditCellWidth(ime_test_preedit[0..3]) orelse 0;
    const expected_col = @min(@as(u32, initial_col) + expected_caret_cells, @as(u32, grid.cols - 1));
    const expected_area = platform.LogicalRect.forCell(expected_col, initial_row, logical_cell, 0);
    imeCheck(out, &failures, area != null and std.meta.eql(area.?.rect, expected_area), "the native candidate area follows the rendered preedit caret", .{});

    try self.window.postTextEditing("", 0, 0);
    imeCheck(out, &failures, try pumpUntil(self, io, out, .text_editing, ime_test_budget_ms), "SDL delivered composition cancellation", .{});
    try self.drawFrame();
    const restored = try self.capture();
    imeCheck(out, &failures, countDifferingPixels(baseline, restored) == 0, "removing the preedit restored the terminal framebuffer exactly", .{});

    const edge_col: u16 = if (grid.cols >= 2) grid.cols - 2 else 0;
    try positionTerminalCursor(self, edge_col, initial_row);
    try self.drawFrame();
    const edge_baseline = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(edge_baseline);
    const sent_before_wide = trace.sent.items.len;
    try self.window.postTextEditing(ime_test_wide, 0, 0);
    imeCheck(out, &failures, try pumpUntil(self, io, out, .text_editing, ime_test_budget_ms), "SDL delivered the right-edge wide preedit", .{});
    try self.drawFrame();
    const edge_composed = try self.allocator.dupe(u8, try self.capture());
    defer self.allocator.free(edge_composed);
    const edge_view = self.ui_canvas.view(&default_palette);
    const edge = overlayCellAt(edge_view, .{ .col = edge_col, .row = initial_row });
    imeCheck(out, &failures, trace.sent.items.len == sent_before_wide and edge_view.cells.len == 1 and edge != null and edge.?.span == .two and std.mem.eql(u8, edge.?.text, "日"), "a wide preedit clips whole graphemes at the right edge and writes no bytes", .{});
    const edge_rect = uiTestCellRect(self, .{ .col = edge_col, .row = initial_row });
    imeCheck(out, &failures, countDifferingPixelsInRect(edge_baseline, edge_composed, self.size, edge_rect) > 0, "the fitting wide grapheme changed framebuffer pixels", .{});

    try self.window.postTextEditing("", 0, 0);
    _ = try pumpUntil(self, io, out, .text_editing, ime_test_budget_ms);
    try self.drawFrame();
    imeCheck(out, &failures, countDifferingPixels(edge_baseline, try self.capture()) == 0, "removing the clipped preedit restored the edge", .{});

    try positionTerminalCursor(self, initial_col, initial_row);
    try self.window.postTextEditing(ime_test_commit, 3, 0);
    _ = try pumpUntil(self, io, out, .text_editing, ime_test_budget_ms);
    const commit_mark = trace.sent.items.len;
    try self.window.postTextInput(ime_test_commit);
    imeCheck(out, &failures, try pumpUntil(self, io, out, .text_input, ime_test_budget_ms), "SDL delivered the committed UTF-8", .{});
    const committed = trace.sent.items[commit_mark..];
    imeCheck(out, &failures, std.mem.eql(u8, committed, ime_test_commit), "the app wrote the committed UTF-8 exactly once ({d} bytes)", .{committed.len});
    var echo_buffer: [64]u8 = undefined;
    const echoed = try waitForEcho(self, io, ime_test_ready, ime_test_commit.len, &echo_buffer);
    imeCheck(out, &failures, std.mem.eql(u8, echoed, ime_test_commit), "the real child received the exact committed UTF-8", .{});
    imeCheck(out, &failures, try waitForChildText(self, io, ime_test_done), "the child completed its exact-length read", .{});
    try self.drawFrame();
    imeCheck(out, &failures, !self.composition.isComposing() and
        self.ui_tree.byId(.{ .value = "ime.preedit" }) == null and
        self.ui_canvas.view(&default_palette).cells.len == 0, "commit removed the semantic preedit and its overlay", .{});

    imeCheck(out, &failures, try waitForScratchpad(self, io, out, .prompt), "the deterministic hidden scratchpad settled before idle measurement", .{});
    try settle(self, out);
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const frames_before = self.scheduler.frames;
    const stats_before = self.focusedGrid().gridStats();
    const idle_deadline = Io.Clock.real.now(io).nanoseconds + 250 * std.time.ns_per_ms;
    try self.run(io, idle_deadline);
    const idle = statDelta(self.focusedGrid().gridStats(), stats_before);
    imeCheck(out, &failures, self.scheduler.frames == frames_before and idle.rows == 0 and idle.draws == 0 and idle.buffer_uploads == 0, "250 ms idle drew zero frames and did zero GPU work", .{});

    // Leave a representative live preedit for --screenshot inspection.
    try positionTerminalCursor(self, initial_col, initial_row);
    // Keep CJK in the byte and clipping assertions above, but use glyphs the
    // bundled JetBrains face owns for the human-facing capture. The middle
    // three letters remain selected, so both the accent underline and the
    // composition selection are visible without a system font fallback.
    try self.window.postTextEditing(ime_test_screenshot_preedit, 2, 3);
    _ = try pumpUntil(self, io, out, .text_editing, ime_test_budget_ms);
    try self.drawFrame();

    out.print("ime-test: {d} failure(s)\n", .{failures}) catch {};
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

/// The TASK-7 integration check, against a real window and real pixels: a
/// surface that clears, events that arrive and are acted on, an idle loop that
/// draws nothing, and a close request that ends the run.
///
/// It drives the app the way a person does — by asking the OS for a resize, and
/// by asking the window to close through SDL's own queue — because Xvfb has no
/// window manager to click and no settings daemon to move a display. Everything
/// it prints is what the run measured, not what it intended: a step that did not
/// happen is reported as not having happened.
fn selfTest(self: *App, io: Io, out: *Writer) !void {
    const window = self.window;
    out.print(
        "self-test: window id {d}, {d}x{d} logical, scale {d:.2}, surface {d}x{d}, visible {}\n",
        .{
            window.id,
            window.state.logical.width,
            window.state.logical.height,
            window.state.scale.factor,
            self.size.width,
            self.size.height,
            window.isVisible(),
        },
    ) catch {};
    // The driver's own pixel size next to the one the scale rule derived: a
    // display where the two disagree shows up here rather than as a stretched
    // image.
    if (window.pixelSize()) |pixels| {
        out.print("self-test: driver pixel size {d}x{d}, scale rule {d}x{d}\n", .{
            pixels.width_px,
            pixels.height_px,
            window.state.surface.width_px,
            window.state.surface.height_px,
        }) catch {};
    }
    out.flush() catch {};

    // 1. The surface is cleared to the background colour, in every pixel of it.
    try self.drawFrame();
    try reportCapture(self, out, "self-test: first frame");

    // 1b. The grid the renderer drew, and what it did to draw it. The check runs
    //     with no child (`wantsChild`), and puts a known line on the screen
    //     first, so the grid has something to draw that is not a program's
    //     output arriving underneath the measurement.
    self.activeLive().terminal().feed("\x1b[2J\x1b[Hconduit self-test\x1b[1;1H");
    // No `refresh` here: `drawFrame` refreshes, and `Terminal.damage` reports the
    // damage of the *last* refresh. Refreshing twice would consume the damage
    // this frame is supposed to draw, and the known line would never reach the
    // surface — which is what the grid check below measures.
    try self.drawFrame();
    const failures = try selfTestGrid(self, out);
    out.print("self-test: {d} grid failure(s)\n", .{failures}) catch {};
    out.flush() catch {};

    // 2. A resize, driven the way a window manager drives one: the app asks the
    //    OS for a size and the event comes back through SDL's queue.
    const target: platform.LogicalSize = .{
        .width = @max(window.state.logical.width / 2, 1),
        .height = @max(window.state.logical.height / 2, 1),
    };
    out.print("self-test: asking the OS for {d}x{d} logical\n", .{ target.width, target.height }) catch {};
    try window.setLogicalSize(target);
    if (try pumpUntil(self, io, out, .{ .resize = target }, self_test_event_budget_ms)) {
        // Drain what is still queued — a window is configured once after it is
        // created, and that resize queues beside the one above — and then draw,
        // because a capture reads the surface as it stands, and the surface was
        // just re-created with nothing drawn into it.
        try settle(self, out);
        if (self.scheduler.shouldDraw()) try self.drawFrame();
        try reportCapture(self, out, "self-test: after resize");
    } else {
        out.print("self-test: NO resize event reported {d}x{d} logical\n", .{ target.width, target.height }) catch {};
    }

    // 3. A display-scale change, driven the way a settings daemon drives one. The
    //    app re-asks the display what it reports and acts on the answer, which is
    //    what makes a scale change a comparison rather than an assumption.
    try window.postDisplayScaleChanged();
    if (!try pumpUntil(self, io, out, .scale, self_test_event_budget_ms)) {
        out.print("self-test: NO display-scale-changed event arrived\n", .{}) catch {};
    }

    // 4. An untouched window. Anything the scale change invalidated is drawn
    //    first, so the interval measured below begins with a surface that matches
    //    the window — otherwise the first iteration's frame would be counted as
    //    idle work when it is really the tail of the event above.
    if (self.scheduler.shouldDraw()) try self.drawFrame();
    const frames_before = self.scheduler.frames;
    const idle_deadline = Io.Clock.real.now(io).nanoseconds + self_test_idle_ms * std.time.ns_per_ms;
    try self.run(io, idle_deadline);
    out.print(
        "self-test: {d} ms with nothing happening drew {d} frames (force_redraw {})\n",
        .{ self_test_idle_ms, self.scheduler.frames - frames_before, self.scheduler.force },
    ) catch {};
    out.flush() catch {};

    // 5. Close, through the same event a window manager's close button sends.
    try window.postCloseRequest();
    if (!try pumpUntil(self, io, out, .close, self_test_event_budget_ms)) {
        out.flush() catch {};
        return error.SelfTestCloseNotDelivered;
    }
    out.print("self-test: the close request ended the run\n", .{}) catch {};
    out.flush() catch {};
}

/// Pump events until one of `awaited` arrives, the budget runs out, or the app
/// decides to stop, printing each event as it is handled.
///
/// Returns whether the awaited event arrived. The events in between are handled
/// rather than discarded, because a real run would react to all of them: a resize
/// arriving with an expose beside it is the ordinary case, not a test artefact.
fn pumpUntil(
    self: *App,
    io: Io,
    out: *Writer,
    awaited: Awaited,
    budget_ms: i64,
) !bool {
    const deadline = Io.Clock.real.now(io).nanoseconds + budget_ms * std.time.ns_per_ms;
    while (true) {
        const event = self.window.pump(eventWaitBudget(io, deadline, false)) orelse {
            if (Io.Clock.real.now(io).nanoseconds >= deadline) return false;
            continue;
        };
        describeEvent(out, event) catch {};
        out.flush() catch {};
        const keep_going = try self.handle(event);
        if (isAwaited(awaited, event)) return true;
        if (!keep_going) return false;
    }
}

/// Handle events until the queue has been quiet for `settle_quiet_ms`, printing
/// each.
///
/// A window is configured once after it is created, and a resize queues beside
/// that, so the first moments of a run carry events nobody asked for. Draining
/// them means the next measurement is taken on a window that has finished moving
/// rather than on one still catching up — and it is what a real run does anyway,
/// because `handle` is where every event is reacted to.
fn settle(self: *App, out: *Writer) !void {
    while (self.window.pump(settle_quiet_ms)) |event| {
        describeEvent(out, event) catch {};
        out.flush() catch {};
        if (!try self.handle(event)) return;
    }
}

/// Write one event as the app saw it, so the sequence a run produced is in its
/// own output and not only in the log file.
fn describeEvent(out: *Writer, event: platform.Event) !void {
    switch (event) {
        .resized => |state| try out.print(
            "  event resized: {d}x{d} logical, surface {d}x{d}\n",
            .{ state.logical.width, state.logical.height, state.surface.width_px, state.surface.height_px },
        ),
        .scale_changed => |change| try out.print(
            "  event display scale changed: {d:.2} -> {d:.2}, surface {d}x{d}\n",
            .{ change.previous.factor, change.state.scale.factor, change.state.surface.width_px, change.state.surface.height_px },
        ),
        .focused => try out.print("  event focus gained\n", .{}),
        .unfocused => try out.print("  event focus lost\n", .{}),
        .exposed => try out.print("  event exposed\n", .{}),
        .close_requested => try out.print("  event close requested\n", .{}),
        .quit => try out.print("  event quit\n", .{}),
        // Pointer events are described rather than named, because for
        // `--mouse-test` the position and the modifiers *are* the measurement:
        // a line reading only "event mouse_button" would report that an event
        // happened, not where it happened or with what held.
        .mouse_button => |button| try out.print(
            "  event mouse button {s} {s} at ({d},{d}) shift={} alt={} ctrl={} super={}\n",
            .{
                @tagName(button.action),
                @tagName(button.button),
                @as(i32, @intFromFloat(@round(button.x))),
                @as(i32, @intFromFloat(@round(button.y))),
                button.mods.shift,
                button.mods.alt,
                button.mods.ctrl,
                button.mods.super,
            },
        ),
        .mouse_motion => |motion| try out.print(
            "  event mouse motion at ({d},{d}) left={} shift={} alt={}\n",
            .{
                @as(i32, @intFromFloat(@round(motion.x))),
                @as(i32, @intFromFloat(@round(motion.y))),
                motion.buttons.left,
                motion.mods.shift,
                motion.mods.alt,
            },
        ),
        // The input slice's events are named rather than described: this
        // function reports what the app saw, and the input path is what turns
        // them into something (TASK-12).
        else => |other| try out.print("  event {s}\n", .{@tagName(std.meta.activeTag(other))}),
    }
}

/// Report one capture: the surface's size, and what is actually in it.
///
/// The pixels come from `capture`, the same path a screenshot takes, and the
/// count is of pixels exactly equal to the background colour. "The surface is the
/// background" is then a measurement of every pixel rather than a claim about the
/// one that happened to be in the corner.
fn reportCapture(self: *App, out: *Writer, label: []const u8) !void {
    const pixels = try self.capture();
    const total = pixels.len / 4;
    const matched = countPixels(pixels, self.background);
    out.print("{s}: surface {d}x{d}, cleared to ", .{ label, self.size.width, self.size.height }) catch {};
    writeColor(out, self.background) catch {};
    out.print(", {d}/{d} pixels are that colour, top-left ", .{ matched, total }) catch {};
    writeColor(out, pixelAt(pixels, self.size, 0, 0)) catch {};
    out.print(", centre ", .{}) catch {};
    writeColor(out, pixelAt(pixels, self.size, self.size.width / 2, self.size.height / 2)) catch {};
    out.print(", bottom-right ", .{}) catch {};
    writeColor(out, pixelAt(pixels, self.size, self.size.width - 1, self.size.height - 1)) catch {};
    out.print("\n", .{}) catch {};
    out.flush() catch {};
}

/// Write a colour as the four bytes a capture holds, so a reader can compare it
/// with the colour the frame was cleared to.
fn writeColor(out: *Writer, color: render.Rgba) !void {
    try out.print("({d},{d},{d},{d})", .{ color.r, color.g, color.b, color.a });
}

/// The pixel at `x`, `y` of a capture, with `y` counted from the top: `read`
/// already flipped the rows, so the buffer is top-down.
fn pixelAt(pixels: []const u8, size: render.Size, x: u32, y: u32) render.Rgba {
    const offset = (@as(usize, y) * size.width + x) * 4;
    return .{ .r = pixels[offset], .g = pixels[offset + 1], .b = pixels[offset + 2], .a = pixels[offset + 3] };
}

/// How many pixels of a capture are exactly `want`.
fn countPixels(pixels: []const u8, want: render.Rgba) usize {
    var matched: usize = 0;
    var offset: usize = 0;
    while (offset + 4 <= pixels.len) : (offset += 4) {
        if (pixels[offset] == want.r and pixels[offset + 1] == want.g and
            pixels[offset + 2] == want.b and pixels[offset + 3] == want.a)
        {
            matched += 1;
        }
    }
    return matched;
}

/// Whether two colours are the same colour, which a capture's pixels and a
/// palette both speak in.
fn sameColor(one: render.Rgba, other: render.Rgba) bool {
    return one.r == other.r and one.g == other.g and one.b == other.b and one.a == other.a;
}

/// How many pixels of `rect` are not `background`. The count that says "there
/// is a glyph here" without claiming anything about its shape.
fn countOther(pixels: []const u8, size: render.Size, rect: render.PixelRect, backdrop: render.Rgba) usize {
    const x_end = @min(size.width, @as(u32, @intFromFloat(rect.x + rect.width)));
    const y_end = @min(size.height, @as(u32, @intFromFloat(rect.y + rect.height)));
    var counted: usize = 0;
    var y: u32 = @intFromFloat(rect.y);
    while (y < y_end) : (y += 1) {
        var x: u32 = @intFromFloat(rect.x);
        while (x < x_end) : (x += 1) {
            if (!sameColor(pixelAt(pixels, size, x, y), backdrop)) counted += 1;
        }
    }
    return counted;
}

/// The pixel in `rect` farthest from `backdrop`, or null when the rectangle is
/// entirely its background. Looking at the strongest coverage pixel makes a
/// glyph's requested foreground measurable without depending on a particular
/// face having a fully opaque texel.
fn farthestPixel(pixels: []const u8, size: render.Size, rect: render.PixelRect, backdrop: render.Rgba) ?render.Rgba {
    const x_end = @min(size.width, @as(u32, @intFromFloat(rect.x + rect.width)));
    const y_end = @min(size.height, @as(u32, @intFromFloat(rect.y + rect.height)));
    var farthest: ?render.Rgba = null;
    var farthest_distance: u32 = 0;
    var y: u32 = @intFromFloat(rect.y);
    while (y < y_end) : (y += 1) {
        var x: u32 = @intFromFloat(rect.x);
        while (x < x_end) : (x += 1) {
            const pixel = pixelAt(pixels, size, x, y);
            const distance = colorDistanceSquared(pixel, backdrop);
            if (distance > farthest_distance) {
                farthest = pixel;
                farthest_distance = distance;
            }
        }
    }
    return farthest;
}

/// Squared RGB distance. Alpha is omitted because the opaque grid background
/// leaves every captured glyph pixel opaque after compositing.
fn colorDistanceSquared(one: render.Rgba, other: render.Rgba) u32 {
    const red = @as(i32, one.r) - @as(i32, other.r);
    const green = @as(i32, one.g) - @as(i32, other.g);
    const blue = @as(i32, one.b) - @as(i32, other.b);
    return @intCast(red * red + green * green + blue * blue);
}

/// The smallest rectangle of device pixels that contains every pixel of `rect`
/// that is not `background`, or null when there is none.
const InkBox = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

fn inkBox(pixels: []const u8, size: render.Size, rect: render.PixelRect, backdrop: render.Rgba) ?InkBox {
    const x_end = @min(size.width, @as(u32, @intFromFloat(rect.x + rect.width)));
    const y_end = @min(size.height, @as(u32, @intFromFloat(rect.y + rect.height)));
    var left: u32 = x_end;
    var top: u32 = y_end;
    var right: u32 = 0;
    var bottom: u32 = 0;
    var y: u32 = @intFromFloat(rect.y);
    while (y < y_end) : (y += 1) {
        var x: u32 = @intFromFloat(rect.x);
        while (x < x_end) : (x += 1) {
            if (sameColor(pixelAt(pixels, size, x, y), backdrop)) continue;
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, x + 1);
            bottom = @max(bottom, y + 1);
        }
    }
    if (right <= left or bottom <= top) return null;
    return .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
}

/// What two captures disagree about: how many pixels moved, and the smallest
/// rectangle containing all of them.
///
/// The count and the box are separate numbers and both are needed. The box
/// says *where* a frame touched, which is what proves it left the rest of the
/// surface alone; the count says *how much* it touched, so a frame that moved
/// one pixel inside the box cannot be mistaken for one that repainted all of
/// it. Reporting `box.width * box.height` as the pixel count — which is what
/// this used to do — overstates it by the empty space inside the box.
const Difference = struct {
    /// How many pixels differ, wherever they are.
    count: u32,
    /// The smallest rectangle containing every differing pixel.
    box: InkBox,

    /// Whether every differing pixel falls inside `rect`.
    pub fn inside(self: Difference, rect: InkBox) bool {
        return self.box.x >= rect.x and self.box.y >= rect.y and
            self.box.x + self.box.width <= rect.x + rect.width and
            self.box.y + self.box.height <= rect.y + rect.height;
    }
};

/// How two captures differ, or null when they are identical. Comparing every
/// pixel of every frame is not a cost worth optimising: this runs inside a
/// check, and a check that guesses which pixels moved is not a check.
fn diffPixels(before: []const u8, after: []const u8, size: render.Size) ?Difference {
    if (before.len != after.len) return null;
    var left: u32 = size.width;
    var top: u32 = size.height;
    var right: u32 = 0;
    var bottom: u32 = 0;
    var count: u32 = 0;
    var y: u32 = 0;
    while (y < size.height) : (y += 1) {
        var x: u32 = 0;
        while (x < size.width) : (x += 1) {
            const offset = (@as(usize, y) * size.width + x) * 4;
            if (std.mem.eql(u8, before[offset..][0..4], after[offset..][0..4])) continue;
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, x + 1);
            bottom = @max(bottom, y + 1);
            count += 1;
        }
    }
    if (count == 0) return null;
    return .{
        .count = count,
        .box = .{ .x = left, .y = top, .width = right - left, .height = bottom - top },
    };
}

/// What changed between two readings of a grid renderer's counters. Differences
/// are what "it did no work" and "it redrew one row" mean; the totals a counter
/// holds are not.
fn statDelta(now: render.GridStats, then: render.GridStats) render.GridStats {
    return .{
        .frames = now.frames - then.frames,
        .skipped_frames = now.skipped_frames - then.skipped_frames,
        .rows = now.rows - then.rows,
        .cells = now.cells - then.cells,
        .backgrounds = now.backgrounds - then.backgrounds,
        .glyphs = now.glyphs - then.glyphs,
        .draws = now.draws - then.draws,
        .buffer_uploads = now.buffer_uploads - then.buffer_uploads,
        .buffer_bytes = now.buffer_bytes - then.buffer_bytes,
        .atlas_uploads = now.atlas_uploads - then.atlas_uploads,
        .atlas_bytes = now.atlas_bytes - then.atlas_bytes,
        .rasterised = now.rasterised - then.rasterised,
    };
}

/// Report one measured claim, and count it as a failure when it did not hold.
fn reportCheck(out: *Writer, ok: bool, comptime format: []const u8, args: anytype) usize {
    out.print("  {s} ", .{if (ok) "ok  " else "FAIL"}) catch {};
    out.print(format, args) catch {};
    out.print("\n", .{}) catch {};
    out.flush() catch {};
    return if (ok) 0 else 1;
}

/// Persist one explicit `--screenshot` without making the render thread do
/// compression or filesystem IO. The event loop has ended before this join.
fn writePngOffThread(
    allocator: Allocator,
    io: Io,
    path: []const u8,
    pixels: []const u8,
    size: render.Size,
) !void {
    const owned_path = try allocator.dupe(u8, path);
    const owned_pixels = allocator.dupe(u8, pixels) catch |err| {
        allocator.free(owned_path);
        return err;
    };
    const job = allocator.create(ScreenshotJob) catch |err| {
        allocator.free(owned_pixels);
        allocator.free(owned_path);
        return err;
    };
    job.* = .{
        .allocator = allocator,
        .io = io,
        .window = null,
        .path = owned_path,
        .pixels = owned_pixels,
        .size = size,
    };
    defer job.deinit();
    try job.start();
    job.thread.?.join();
    job.thread = null;
    if (job.failure) |name| {
        log.err("screenshot persistence failed: {s}", .{name});
        return error.ScreenshotWriteFailed;
    }
}

// ---------------------------------------------------------------------------
// The grid check (--grid-test)
// ---------------------------------------------------------------------------

/// The grid the check draws: wide enough for a two-cell glyph and three cells
/// of control.
const check_columns = 12;
const check_rows = 5;

/// The character whose wide cell the check measures: U+6F22.
const wide_codepoint: u21 = 0x6f22;

/// A family that has CJK glyphs, tried when the requested one does not. It is
/// the second candidate rather than the first because a run should draw with
/// whatever family it was asked for; this only makes the wide-glyph row
/// measurable when the first family cannot.
const cjk_family = "Noto Sans Mono CJK SC";

/// The screen the check draws, written as a program would print it.
///
/// Row 0 carries one `A` in each face style, followed after two blank cells by
/// a concealed, decorated cell with an explicit background. Row 1 is a whole
/// row of pure red, set with a 24-bit SGR, so a background colour can be read
/// back as exactly itself. Row 2 is one inverse cell. Row 3 is a wide CJK
/// glyph, which owns two cells. Row 4 is a base letter with a combining acute
/// beside a plain one, so the mark can be shown to stay inside its own cell's
/// advance.
const check_screen =
    "\x1b[0m\x1b[2J\x1b[H" ++
    "A" ++
    "\x1b[1;31mA" ++
    "\x1b[0;3mA" ++
    "\x1b[0;1;3mA" ++
    "\x1b[0m  " ++
    "\x1b[4;9;53;8;38;5;15;48;2;12;34;56mC\x1b[0m\r\n" ++
    "\x1b[48;2;255;0;0m            \x1b[0m\r\n" ++
    "\x1b[7m \x1b[0m\r\n" ++
    "\xe6\xbc\xa2\x1b[0m\r\n" ++
    "e\xcc\x81e\x1b[0m";

/// The grid renderer's own check: the same screen drawn at two display scales,
/// read back pixel by pixel, with the work each frame did counted rather than
/// asserted.
fn gridTest(io: Io, allocator: Allocator, env: EnvSource, family: []const u8, out: *Writer) !u8 {
    var failures: usize = 0;
    // Two scales rather than one: a renderer that scales its output up is
    // correct at 1 and wrong everywhere else, and only the second run can tell
    // the two apart.
    for ([_]f32{ 1.0, 2.0 }) |scale| {
        failures += try gridTestAtScale(io, allocator, env, family, scale, out);
    }
    try out.print("grid-test: {s}, {d} failure(s)\n", .{
        if (failures == 0) "PASS" else "FAIL",
        failures,
    });
    out.flush() catch {};
    return if (failures == 0) 0 else 1;
}

fn gridTestAtScale(
    io: Io,
    allocator: Allocator,
    env: EnvSource,
    family: []const u8,
    scale: f32,
    out: *Writer,
) !usize {
    const size = font.Size.init(font_points, scale) catch |err| {
        try out.print("grid-test: a display scale of {d:.2} is not a usable font size: {s}\n", .{
            scale,
            @errorName(err),
        });
        return 1;
    };

    // The wide-glyph row is only measurable with a face that has a CJK glyph,
    // so a family that has one is preferred — but only after the family the run
    // asked for has been tried, because that is the family a user would see.
    var chosen: ?font.Manager = null;
    for ([_][]const u8{ family, cjk_family }) |candidate| {
        var manager = font.Manager.init(allocator, io, .{
            .family = candidate,
            .size = size,
            .home_dir = env.get("HOME"),
            .atlas_width_px = atlas_width_px,
            .atlas_height_px = atlas_height_px,
        }) catch |err| {
            try out.print("grid-test: scale {d:.2}: {s} could not be loaded: {s}\n", .{
                scale,
                candidate,
                @errorName(err),
            });
            continue;
        };
        if (manager.glyphIndex(wide_codepoint) != 0) {
            // This one can draw the wide row, so it replaces whatever was held.
            var previous: ?font.Manager = chosen;
            chosen = manager;
            if (previous) |*held| held.deinit();
            break;
        }
        // Otherwise it is only kept while nothing better has turned up yet.
        if (chosen == null) {
            chosen = manager;
        } else {
            var unused = manager;
            unused.deinit();
        }
    }
    var fonts = chosen orelse {
        try out.print("grid-test: scale {d:.2}: no face could be loaded at all\n", .{scale});
        return 1;
    };
    defer fonts.deinit();

    const metrics = fonts.metrics();
    const cell = metrics.cell;
    const has_wide_glyph = fonts.glyphIndex(wide_codepoint) != 0;
    try out.print(
        "grid-test: scale {d:.2}: {s} from {s}, cell {d}x{d}px, baseline {d}px, U+6F22 {s}\n",
        .{
            scale,
            fonts.familyName(),
            fonts.sourcePath(),
            cell.width_px,
            cell.height_px,
            metrics.baseline_px,
            if (has_wide_glyph) "present" else "MISSING",
        },
    );

    const surface_size: render.Size = .{
        .width = cell.width_px * check_columns,
        .height = cell.height_px * check_rows,
    };
    var surface = try render.Surface.init(surface_size);
    defer surface.deinit();

    var grid = try render.Grid.init(allocator, gridColors(default_palette));
    defer grid.deinit();
    try grid.attachAtlas(fonts.atlasPixels(), .{
        .width_px = atlas_width_px,
        .height_px = atlas_height_px,
    });

    var terminal: term.Terminal = undefined;
    try terminal.init(io, allocator, try term.GridSize.init(check_columns, check_rows));
    defer terminal.deinit(allocator);

    const capture = try allocator.alloc(u8, render.readbackLen(surface_size));
    defer allocator.free(capture);
    // A second buffer, so the pixels before a partial frame can be compared
    // with the pixels after it. That comparison is what "the rest of the
    // surface was left alone" means.
    const earlier = try allocator.alloc(u8, render.readbackLen(surface_size));
    defer allocator.free(earlier);

    const colors = gridColors(default_palette);
    const backdrop = colors.background;
    var failures: usize = 0;
    const red: render.Rgba = .{ .r = 255, .g = 0, .b = 0 };

    terminal.feed(check_screen);
    try terminal.refresh(allocator);
    try grid.draw(&surface, &fonts, &terminal, true);
    const pixels = try surface.read(capture);

    // 1. A background colour is the colour that was asked for, in every pixel of
    //    the row it was set on. Spaces draw no glyph, so the row is nothing but
    //    its background and the count is the whole row.
    const red_row_area = @as(usize, cell.width_px) * cell.height_px * check_columns;
    const red_count = countPixels(pixels, red);
    const red_centre = pixelAt(pixels, surface_size, cell.width_px * 6, cell.height_px + cell.height_px / 2);
    failures += reportCheck(out, red_count == red_row_area, "row 1 background: {d}/{d} pixels are exactly (255,0,0), centre pixel {d},{d},{d}", .{
        red_count, red_row_area, red_centre.r, red_centre.g, red_centre.b,
    });

    // 2. A letter in the default colours puts pixels that are not the background
    //    inside its own cell. Cell 5 is deliberately blank and separated from
    //    the italic samples, so it stays background-only even when a face has
    //    an overhang.
    const letter_cell = render.cellRect(0, 0, cell);
    const letter_ink = countOther(pixels, surface_size, letter_cell, backdrop);
    const blank_ink = countOther(pixels, surface_size, render.cellRect(5, 0, cell), backdrop);
    failures += reportCheck(out, letter_ink > 0 and blank_ink == 0, "row 0 regular 'A': {d} inked pixels; separated blank cell has {d}", .{
        letter_ink, blank_ink,
    });

    // Bold, italic and bold-italic all arrive through the same terminal byte
    // path as a real program's SGR output. Their pixels may be identical when
    // the bundled regular-only fallback is in use, so the deterministic claim
    // is that the terminal retained each style and each cell produced ink.
    const bold_cell = terminal.cell(.{ .col = 1, .row = 0 });
    const italic_cell = terminal.cell(.{ .col = 2, .row = 0 });
    const bold_italic_cell = terminal.cell(.{ .col = 3, .row = 0 });
    const bold_attributes_ok = bold_cell != null and bold_cell.?.style.attributes.bold and
        !bold_cell.?.style.attributes.italic and bold_cell.?.style.fg.eql(.{ .palette = 1 });
    const italic_attributes_ok = italic_cell != null and !italic_cell.?.style.attributes.bold and
        italic_cell.?.style.attributes.italic;
    const bold_italic_attributes_ok = bold_italic_cell != null and bold_italic_cell.?.style.attributes.bold and
        bold_italic_cell.?.style.attributes.italic;
    failures += reportCheck(out, bold_attributes_ok and italic_attributes_ok and bold_italic_attributes_ok, "row 0 SGR styles: bold+red={}, italic={}, bold-italic={}", .{
        bold_attributes_ok, italic_attributes_ok, bold_italic_attributes_ok,
    });

    const bold_ink = countOther(pixels, surface_size, render.cellRect(1, 0, cell), backdrop);
    const italic_ink = countOther(pixels, surface_size, render.cellRect(2, 0, cell), backdrop);
    const bold_italic_ink = countOther(pixels, surface_size, render.cellRect(3, 0, cell), backdrop);
    failures += reportCheck(out, bold_ink > 0 and italic_ink > 0 and bold_italic_ink > 0, "row 0 styled 'A' ink: bold {d}px, italic {d}px, bold-italic {d}px", .{
        bold_ink, italic_ink, bold_italic_ink,
    });

    // SGR 1 changes the face, not an explicit foreground. The most-covered
    // pixel of the bold red glyph must therefore be closer to ANSI red than
    // bright red. This remains deterministic with antialiasing and with a
    // regular-only fallback because it does not assert a particular outline.
    const ansi_red = colors.ansi[1];
    const bright_red = colors.ansi[9];
    if (farthestPixel(pixels, surface_size, render.cellRect(1, 0, cell), backdrop)) |strongest| {
        const red_distance = colorDistanceSquared(strongest, ansi_red);
        const bright_distance = colorDistanceSquared(strongest, bright_red);
        failures += reportCheck(out, red_distance < bright_distance, "row 0 bold red: strongest pixel ({d},{d},{d}) is {d} from ANSI red and {d} from bright red", .{
            strongest.r, strongest.g, strongest.b, red_distance, bright_distance,
        });
    } else {
        failures += reportCheck(out, false, "row 0 bold red: the cell has no foreground pixel to measure", .{});
    }

    // Conceal suppresses the glyph and every foreground decoration, but not
    // the cell's explicit background. Two blank cells separate this sample
    // from the italic faces so an intentional glyph overhang cannot enter it.
    const concealed_cell = terminal.cell(.{ .col = 6, .row = 0 });
    const concealed_attributes_ok = concealed_cell != null and concealed_cell.?.style.attributes.invisible and
        concealed_cell.?.style.attributes.underline == .single and concealed_cell.?.style.attributes.strikethrough and
        concealed_cell.?.style.attributes.overline;
    failures += reportCheck(out, concealed_attributes_ok, "row 0 concealed cell: invisible+underline+strike+overline={}", .{concealed_attributes_ok});
    const concealed_background: render.Rgba = .{ .r = 12, .g = 34, .b = 56 };
    const concealed_rect = render.cellRect(6, 0, cell);
    const concealed_foreground = countOther(pixels, surface_size, concealed_rect, concealed_background);
    const concealed_centre = pixelAt(pixels, surface_size, cell.width_px * 6 + cell.width_px / 2, cell.height_px / 2);
    failures += reportCheck(out, concealed_foreground == 0 and sameColor(concealed_centre, concealed_background), "row 0 concealed cell: {d} non-background pixels, centre ({d},{d},{d})", .{
        concealed_foreground, concealed_centre.r, concealed_centre.g, concealed_centre.b,
    });

    // 3. A wide glyph owns two cells: the engine says so, and the pixels of both
    //    halves are inside the cell the glyph was written to.
    const wide_left = terminal.cell(.{ .col = 0, .row = 3 });
    const wide_right = terminal.cell(.{ .col = 1, .row = 3 });
    const wide_ink_left = countOther(pixels, surface_size, render.cellRect(0, 3, cell), backdrop);
    const wide_ink_right = countOther(pixels, surface_size, render.cellRect(1, 3, cell), backdrop);
    const wide_ink_after = countOther(pixels, surface_size, render.cellRect(2, 3, cell), backdrop);
    failures += reportCheck(out, wide_left != null and wide_left.?.wide and
        wide_right != null and wide_right.?.wide_tail, "row 3: cell 0 wide={}, cell 1 wide_tail={}", .{
        wide_left.?.wide, wide_right.?.wide_tail,
    });
    failures += reportCheck(out, wide_ink_after == 0, "row 3: cell 2 has {d} inked pixels, so the glyph stopped at two cells", .{
        wide_ink_after,
    });
    failures += reportCheck(out, !has_wide_glyph or (wide_ink_left > 0 and wide_ink_right > 0), "row 3: ink {d} px in cell 0 and {d} px in cell 1", .{ wide_ink_left, wide_ink_right });

    // 4. A combining mark stays inside the advance of the cell it belongs to:
    //    the marked letter's ink does not cross into the plain letter's cell,
    //    and it reaches higher than the plain one because of the accent.
    const marked = inkBox(pixels, surface_size, render.cellRect(0, 4, cell), backdrop);
    const plain = inkBox(pixels, surface_size, render.cellRect(1, 4, cell), backdrop);
    const marked_width = if (marked) |box| box.x + box.width else 0;
    const marked_top = if (marked) |box| box.y else 0;
    const plain_top = if (plain) |box| box.y else marked_top;
    failures += reportCheck(out, marked != null and plain != null and marked_width <= cell.width_px, "row 4: 'e'+U+0301 ink ends at x={d} of a {d}px cell", .{ marked_width, cell.width_px });
    failures += reportCheck(out, marked != null and plain != null and marked_top < plain_top, "row 4: the marked letter reaches y={d}, the plain one y={d}", .{ marked_top, plain_top });

    // 5. The cursor is drawn in the terminal's colour, over the cell the engine
    //    says it is on.
    const state = terminal.cursor();
    if (state.position) |at| {
        const cursor_centre = render.cellRect(at.col, at.row, cell);
        const x: u32 = @intFromFloat(cursor_centre.x + cursor_centre.width / 2);
        const y: u32 = @intFromFloat(cursor_centre.y + cursor_centre.height / 2);
        const got = pixelAt(pixels, surface_size, x, y);
        failures += reportCheck(out, sameColor(got, colors.cursor), "cursor: {s} at ({d},{d}), centre pixel {d},{d},{d}", .{
            @tagName(state.shape), at.col, at.row, got.r, got.g, got.b,
        });
    } else {
        failures += reportCheck(out, false, "cursor: the terminal reported no position", .{});
    }

    // 6. Damage: a frame with nothing to do does nothing. Every counter is
    //    printed, because "the boolean was false" is not the claim.
    try out.print("  -- one frame with no change --\n", .{});
    const before_idle = grid.gridStats();
    try terminal.refresh(allocator);
    try grid.draw(&surface, &fonts, &terminal, true);
    const idle = statDelta(grid.gridStats(), before_idle);
    try reportDamage(out, terminal.damage());
    failures += reportCheck(out, idle.frames == 0 and idle.skipped_frames == 1 and idle.rows == 0 and
        idle.cells == 0 and idle.glyphs == 0 and idle.draws == 0 and idle.buffer_uploads == 0 and
        idle.buffer_bytes == 0 and idle.atlas_uploads == 0, "idle frame: frames {d}, skipped {d}, rows {d}, cells {d}, glyphs {d}, draws {d}, buffer uploads {d} ({d} B), atlas uploads {d}", .{
        idle.frames,         idle.skipped_frames, idle.rows,          idle.cells, idle.glyphs, idle.draws,
        idle.buffer_uploads, idle.buffer_bytes,   idle.atlas_uploads,
    });

    // 7. A cursor that moves is a change of its own, and it is measured on its
    //    own. The row it left holds its pixels and has to be repainted; so does
    //    the row it reached. This was folded into the row check below, which is
    //    why that check hides the cursor first: a change that moves the cursor
    //    is never a change confined to one row, and asserting that it was is
    //    what made the row check fail against a correct renderer.
    try out.print("  -- the cursor leaves ({d},{d}) for row 1 --\n", .{ 2, check_rows - 1 });
    _ = try surface.read(earlier);
    const before_move = grid.gridStats();
    terminal.feed("\x1b[2;1H");
    try terminal.refresh(allocator);
    const move_damage = terminal.damage();
    try grid.draw(&surface, &fonts, &terminal, true);
    const moved = statDelta(grid.gridStats(), before_move);
    try reportDamage(out, move_damage);
    failures += reportCheck(out, damageIs(move_damage, &.{ 1, check_rows - 1 }), "cursor move: the terminal damaged the row it left and the row it reached", .{});
    failures += reportCheck(out, moved.rows == 2 and moved.cells == 2 * check_columns, "cursor move: {d} rows, {d} cells, {d} draws — the two damaged rows and no others", .{
        moved.rows, moved.cells, moved.draws,
    });
    // The row the cursor left really was repainted: the cell it was on is that
    // row's own background again, not the cursor's colour.
    const vacated = render.cellRect(2, check_rows - 1, cell);
    const after_move = try surface.read(capture);
    const vacated_pixel = pixelAt(after_move, surface_size, @intFromFloat(vacated.x + vacated.width / 2), @intFromFloat(vacated.y + vacated.height / 2));
    failures += reportCheck(out, !sameColor(vacated_pixel, colors.cursor), "cursor move: the cell it left at (2,{d}) is ({d},{d},{d}), not the cursor colour", .{
        check_rows - 1, vacated_pixel.r, vacated_pixel.g, vacated_pixel.b,
    });

    // The cursor is hidden from here on. A cursor whose pixels move is a second
    // change on top of whatever is written below, and each claim below is about
    // one change at a time.
    terminal.feed("\x1b[?25l");
    try terminal.refresh(allocator);
    try grid.draw(&surface, &fonts, &terminal, true);

    // 8. Damage: one changed row redraws one row, and only that one. The
    //    characters written are ones the atlas already holds — 'A' is on row 0
    //    already — so the rasterise and upload counts have to stay at zero as
    //    well: that is what proves a row whose glyphs the atlas already holds
    //    costs no upload.
    try out.print("  -- one changed row --\n", .{});
    _ = try surface.read(earlier);
    const before_row = grid.gridStats();
    terminal.feed("\x1b[48;2;255;0;0mAAAA");
    try terminal.refresh(allocator);
    const row_damage = terminal.damage();
    try grid.draw(&surface, &fonts, &terminal, true);
    const one_row = statDelta(grid.gridStats(), before_row);
    try reportDamage(out, row_damage);
    failures += reportCheck(out, damageIs(row_damage, &.{1}), "one changed row: the terminal damaged row 1 and nothing else", .{});
    failures += reportCheck(out, one_row.rows == 1 and one_row.cells == check_columns and
        one_row.backgrounds == check_columns, "one changed row: {d} rows, {d} cells, {d} backgrounds, {d} glyphs", .{
        one_row.rows, one_row.cells, one_row.backgrounds, one_row.glyphs,
    });
    failures += reportCheck(out, one_row.atlas_uploads == 0 and one_row.rasterised == 0, "one changed row: {d} glyphs rasterised, {d} atlas uploads", .{
        one_row.rasterised, one_row.atlas_uploads,
    });
    failures += reportCheck(out, one_row.buffer_uploads >= 1, "one changed row: {d} buffer uploads ({d} B)", .{
        one_row.buffer_uploads, one_row.buffer_bytes,
    });
    // Every pixel that moved is inside the row that changed. Not that the
    // renderer says it skipped the others: that the surface outside that row is
    // bit-for-bit what it was.
    const row_rect = InkBox{
        .x = 0,
        .y = cell.height_px,
        .width = surface_size.width,
        .height = cell.height_px,
    };
    const after_row = try surface.read(capture);
    if (diffPixels(earlier, after_row, surface_size)) |diff| {
        failures += reportCheck(out, diff.inside(row_rect), "one changed row: {d} pixels differ, ({d},{d})-({d},{d}); the row is (0,{d})-({d},{d})", .{
            diff.count, diff.box.x,                  diff.box.y,                   diff.box.x + diff.box.width, diff.box.y + diff.box.height,
            row_rect.y, row_rect.x + row_rect.width, row_rect.y + row_rect.height,
        });
    } else {
        failures += reportCheck(out, false, "one changed row: no pixel changed at all, so nothing was written", .{});
    }

    // 9. Damage: one changed cell moves that cell's pixels and nothing else.
    //    The four 'A's the row check above wrote leave the cursor on the fifth
    //    cell of the same row, so this writes one cell without moving the
    //    cursor off its row and without needing a new glyph.
    try out.print("  -- one changed cell --\n", .{});
    _ = try surface.read(earlier);
    const before_cell = grid.gridStats();
    terminal.feed("A");
    try terminal.refresh(allocator);
    const cell_damage = terminal.damage();
    try grid.draw(&surface, &fonts, &terminal, true);
    const one_cell = statDelta(grid.gridStats(), before_cell);
    try reportDamage(out, cell_damage);
    failures += reportCheck(out, damageIs(cell_damage, &.{1}), "one changed cell: the terminal damaged row 1 and nothing else", .{});
    failures += reportCheck(out, one_cell.rows == 1 and one_cell.cells == check_columns, "one changed cell: {d} rows, {d} cells, {d} backgrounds, {d} glyphs", .{
        one_cell.rows, one_cell.cells, one_cell.backgrounds, one_cell.glyphs,
    });
    const cell_rect = inkBounds(render.cellRect(4, 1, cell));
    const after_cell = try surface.read(capture);
    if (diffPixels(earlier, after_cell, surface_size)) |diff| {
        failures += reportCheck(out, diff.inside(cell_rect), "one changed cell: {d} pixels differ, ({d},{d})-({d},{d}); the cell is ({d},{d})-({d},{d})", .{
            diff.count,  diff.box.x,  diff.box.y,                    diff.box.x + diff.box.width,    diff.box.y + diff.box.height,
            cell_rect.x, cell_rect.y, cell_rect.x + cell_rect.width, cell_rect.y + cell_rect.height,
        });
    } else {
        failures += reportCheck(out, false, "one changed cell: no pixel changed at all, so the cell was not written", .{});
    }

    // 10. The cursor coming back. Hiding it repainted the row it was on and
    //     took its pixels with it; showing it again has to put them back, or a
    //     cursor a program un-hides never reappears until something else
    //     changes the screen. The terminal reports no damage at all here, so
    //     this is the frame the renderer has to reason about on its own — which
    //     is the whole of what the cursor bookkeeping is for.
    try out.print("  -- the cursor comes back --\n", .{});
    _ = try surface.read(earlier);
    const before_reveal = grid.gridStats();
    terminal.feed("\x1b[?25h");
    try terminal.refresh(allocator);
    const reveal_damage = terminal.damage();
    const revealed_state = terminal.cursor();
    try grid.draw(&surface, &fonts, &terminal, true);
    const revealed = statDelta(grid.gridStats(), before_reveal);
    try reportDamage(out, reveal_damage);
    failures += reportCheck(out, damageIs(reveal_damage, &.{}), "cursor back: the terminal reported no damage — nothing but the cursor changed", .{});
    failures += reportCheck(out, revealed.rows == 1 and revealed.cells == check_columns, "cursor back: {d} rows, {d} cells, {d} draws — the cursor's row and no other", .{
        revealed.rows, revealed.cells, revealed.draws,
    });
    if (revealed_state.position) |at| {
        const rect = render.cellRect(at.col, at.row, cell);
        const after_reveal = try surface.read(capture);
        const centre = pixelAt(after_reveal, surface_size, @intFromFloat(rect.x + rect.width / 2), @intFromFloat(rect.y + rect.height / 2));
        failures += reportCheck(out, sameColor(centre, colors.cursor), "cursor back: the cell at ({d},{d}) is ({d},{d},{d}), the cursor colour", .{
            at.col, at.row, centre.r, centre.g, centre.b,
        });
        // And the rest of the surface is bit-for-bit what it was.
        if (diffPixels(earlier, after_reveal, surface_size)) |diff| {
            failures += reportCheck(out, diff.inside(row_rect), "cursor back: {d} pixels differ, ({d},{d})-({d},{d}); the row is (0,{d})-({d},{d})", .{
                diff.count, diff.box.x,                  diff.box.y,                   diff.box.x + diff.box.width, diff.box.y + diff.box.height,
                row_rect.y, row_rect.x + row_rect.width, row_rect.y + row_rect.height,
            });
        } else {
            failures += reportCheck(out, false, "cursor back: no pixel changed at all, so the cursor did not come back", .{});
        }
    } else {
        failures += reportCheck(out, false, "cursor back: the terminal reported no position", .{});
    }

    return failures;
}

/// A cell rectangle as whole-pixel bounds, so a diff box can be compared with it.
fn inkBounds(rect: render.PixelRect) InkBox {
    const x: u32 = @intFromFloat(rect.x);
    const y: u32 = @intFromFloat(rect.y);
    return .{
        .x = x,
        .y = y,
        .width = @as(u32, @intFromFloat(rect.x + rect.width)) - x,
        .height = @as(u32, @intFromFloat(rect.y + rect.height)) - y,
    };
}

/// What the terminal said changed, as the note above a check's own numbers.
///
/// A renderer is only accountable for the rows it was handed, so a damage claim
/// that does not say what it was handed is not a claim anybody can check.
fn reportDamage(out: *Writer, damage: term.Damage) !void {
    try out.print("    ", .{});
    switch (damage) {
        .none => try out.print("damage: nothing changed", .{}),
        .full => try out.print("damage: the whole grid", .{}),
        .rows => |rows| {
            try out.print("damage: {d} row(s) [", .{rows.len});
            for (rows, 0..) |row, i| {
                if (i > 0) try out.print(",", .{});
                try out.print("{d}", .{row});
            }
            try out.print("]", .{});
        },
    }
    try out.print("\n", .{});
}

/// Whether the terminal's damage is exactly `expected`.
fn damageIs(damage: term.Damage, expected: []const u16) bool {
    return switch (damage) {
        .rows => |rows| std.mem.eql(u16, expected, rows),
        .none => expected.len == 0,
        .full => false,
    };
}

/// What `--self-test` says about the grid, on the grid the run actually has.
fn selfTestGrid(self: *App, out: *Writer) !usize {
    var failures: usize = 0;
    const cell = self.fonts.metrics().cell;
    const grid_size = self.activeLive().terminal().gridSize();
    try out.print(
        "self-test: grid {d}x{d} cells of {d}x{d}px, drawn with {s}\n",
        .{ grid_size.cols, grid_size.rows, cell.width_px, cell.height_px, self.fonts.familyName() },
    );
    try out.flush();

    const drawn = self.focusedGrid().gridStats();
    try out.print(
        "self-test: the grid has drawn {d} rows, {d} backgrounds, {d} glyphs, rasterised {d}, {d} atlas upload(s), {d} buffer upload(s)\n",
        .{ drawn.rows, drawn.backgrounds, drawn.glyphs, drawn.rasterised, drawn.atlas_uploads, drawn.buffer_uploads },
    );
    failures += reportCheck(out, drawn.glyphs > 0, "self-test: the first frame put {d} glyphs on the surface", .{drawn.glyphs});

    const before = self.focusedGrid().gridStats();
    try self.drawFrame();
    const idle = statDelta(self.focusedGrid().gridStats(), before);
    failures += reportCheck(out, idle.rows == 0 and idle.buffer_uploads == 0 and idle.skipped_frames == 1, "self-test: a second frame with no change drew {d} rows, {d} buffer uploads, {d} atlas uploads", .{
        idle.rows, idle.buffer_uploads, idle.atlas_uploads,
    });

    const state = self.activeLive().terminal().cursor();
    if (state.position) |at| {
        const rect = render.cellRect(at.col, at.row, cell);
        const pixels = try self.capture();
        const got = pixelAt(pixels, self.size, @intFromFloat(rect.x + rect.width / 2), @intFromFloat(rect.y + rect.height / 2));
        failures += reportCheck(out, sameColor(got, gridColors(default_palette).cursor), "self-test: the {s} cursor at ({d},{d}) is drawn as ({d},{d},{d})", .{
            @tagName(state.shape), at.col, at.row, got.r, got.g, got.b,
        });
    }
    return failures;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/// Usage text. Terse and terminal-like, like the rest of the UI.
const usage =
    \\conduit — usage
    \\
    \\  conduit [--log-level=<level>] [--log-file=<path>] [--log-dir=<dir>]
    \\          [--width=<px>] [--height=<px>] [--scale=<factor>] [--hidden]
    \\          [--run-ms=<ms>]
    \\          [--force-redraw] [--self-test] [--print-log-path] [--help]
    \\          [--version]
    \\          [--command=<line>] [--screenshot=<path>] [--font=<family>]
    \\          [--grid-test] [--scroll-test] [--mouse-test] [--clipboard-test]
    \\          [--ui-test] [--ime-test] [--sidebar-test] [--tabs-test]
    \\          [--panes-test] [--scratchpad-test] [--palette-test]
    \\          [--workspaces-test] [--links-test] [--search-test]
    \\          [--test-driver=<endpoint>]
    \\          [--test-artifact-dir=<dir>]
    \\          [--driver-test]
    \\          [--no-child] [--no-shell-integration]
    \\
    \\  --log-level=<err|warn|info|debug>  minimum level written (default: debug
    \\                                    in a debug build, info in a release one)
    \\  --log-file=<path>                  log to exactly this path
    \\  --log-dir=<dir>                    put the per-run log in this directory
    \\  --print-log-path                   print the log path, then exit
    \\  --help                             print this, then exit
    \\
    \\  --width=<px> --height=<px>         the window's size in logical pixels
    \\                                    (default: 960x640)
    \\  --scale=<factor>                   fix physical pixels per logical pixel
    \\                                    (default: follow the display)
    \\  --hidden                           create the window hidden and never show it;
    \\                                    the GL context is real either way
    \\  --run-ms=<ms>                      leave cleanly after this long instead of
    \\                                    waiting for the window to be closed
    \\  --force-redraw                     draw every frame, to measure against
    \\  --self-test                        run the window/GPU integration check,
    \\                                    print what it measured, then exit
    \\
    \\  --command=<line>                   run this line with /bin/sh -c instead of
    \\                                    an interactive shell, and leave when it
    \\                                    does
    \\  --screenshot=<path>                write the last frame as an RGBA PNG
    \\  --font=<family>                    draw the grid with this family (default:
    \\                                    the bundled JetBrains Mono)
    \\  --grid-test                        draw a known screen at scale 1 and 2,
    \\                                    read it back pixel by pixel, print what
    \\                                    each frame did, then exit
    \\  --scroll-test                      print numbered lines, scroll back through
    \\                                    history with a real wheel event, read the
    \\                                    surface back and print what it showed,
    \\                                    then exit
    \\  --mouse-test                       drive real drags and repeated clicks through
    \\                                    SDL's queue into the terminal, prove Shift,
    \\                                    scrolling, word and line selection, read the
    \\                                    surface back and print what it measured,
    \\                                    then exit
    \\  --clipboard-test                   on SDL's offscreen driver (process-local
    \\                                    clipboards only, never the display's):
    \\                                    copy a selection, paste it bracketed into
    \\                                    a real child, normalize a multi-line paste,
    \\                                    middle-click the primary selection, check
    \\                                    Ctrl+C and OSC 52 under allow, ask and
    \\                                    deny, print the exact bytes, then exit
    \\  --ui-test                          draw all four UI primitives over terminal
    \\                                    cells in a fixed hidden 640x360 window,
    \\                                    drive one real key, measure and exit
    \\  --ime-test                         drive inline IME preedit and commit through
    \\                                    SDL and a real PTY, measure and exit
    \\  --sidebar-test                     drive production sidebar tab switching,
    \\                                    toggle and resizing paths, measure and exit
    \\  --tabs-test                        drive production tab lifecycle, attention,
    \\                                    confirmation and reorder paths, then exit
    \\  --panes-test                       drive nested pane split, focus, resize,
    \\                                    zoom and close with real PTY peers, then exit
    \\  --scratchpad-test                  drive persistent scratchpad show, hide,
    \\                                    input isolation and restart, then exit
    \\  --palette-test                     drive fuzzy command search, keyboard and
    \\                                    mouse activation and nested arguments
    \\  --workspaces-test                  drive two independent workspaces, layouts,
    \\                                    scratchpads and close lifecycle, then exit
    \\  --links-test                       drive URL and OSC 8 semantics, native-modifier
    \\                                    hover and clicks through SDL, then exit
    \\  --search-test                      drive inline full-scrollback search, navigation,
    \\                                    case mode and invalidation through SDL, then exit
    \\  --menu-test                        drive the right-click context menu, its keyboard
    \\                                    path, the paste alternative and DEC mouse
    \\                                    reporting through SDL, then exit
    \\  --right-click=<menu|paste>         what a right click over a terminal does when
    \\                                    the program has not captured the mouse
    \\                                    (default: menu)
    \\  --test-driver=<endpoint>           enable the local JSON-RPC automation server
    \\                                    at this Unix socket or Windows pipe
    \\  --test-artifact-dir=<dir>          write driver screenshots into this run's
    \\                                    artifact directory without overwriting
    \\  --driver-test                      exercise the automation server and exit
    \\  --no-child                         run a terminal with nothing behind it
    \\  --no-shell-integration             start the shell without Conduit's bash or
    \\                                    zsh integration: no working-directory or
    \\                                    prompt reports from Conduit's scripts
    \\
    \\  Environment fallbacks, used when the matching flag is absent:
    \\    CONDUIT_LOG_LEVEL, CONDUIT_LOG_FILE, CONDUIT_LOG_DIR
    \\  A flag always wins over the environment.
    \\
;

/// Start the app. `main` returning is the clean exit: the window, the GL context
/// and the surface are gone by then, and the process allocator has nothing of
/// Conduit's left in it.
pub fn main(init: std.process.Init) !void {
    const args = try collectArgs(init.arena.allocator(), init.minimal.args);
    const options = parseArgs(args, processEnv(init)) catch |err| {
        try writeStderrText("conduit: ");
        try writeStderrText(@errorName(err));
        try writeStderrText("\n\n");
        try writeStderrText(usage);
        std.process.exit(2);
    };

    if (options.help) {
        try writeStdout(init.io, usage);
        return;
    }
    // Answered before the log sink, SDL or any display work so packages can
    // prove their stamped version on a headless machine.
    if (options.print_version) {
        try writeStdout(init.io, "conduit " ++ version ++ "\n");
        return;
    }

    sink.install(init.io, options) catch |err| {
        // A log file that cannot be opened costs the file, not the run: the
        // sink is already installed, so stderr keeps working at the resolved
        // level. This message is written with `writeStderrText` rather than
        // `log.err` because it is about the log, and the level is not settled
        // from the caller's point of view yet.
        try writeStderrText("conduit: cannot open a log file (");
        try writeStderrText(@errorName(err));
        try writeStderrText("); continuing with stderr only\n");
    };

    const status = startRun(init, options) catch |err| blk: {
        log.err("conduit stopped: {s}", .{@errorName(err)});
        break :blk 1;
    };

    // The log file is flushed and closed while the sink stays installed, so the
    // leak report the process allocator prints on its way out still reaches
    // stderr. See `Sink.closeFile`.
    sink.closeFile();
    if (status != 0) std.process.exit(status);
}

/// Everything the run does once logging is up, in one place.
///
/// Split from `main` so that every path through it — help, a printed log path, a
/// normal run, a failure — ends at the same line, which closes the log file.
fn startRun(init: std.process.Init, options: Options) !u8 {
    log.info("conduit {s} starting on {s}", .{ version, buildTarget(&target_buf) catch "unknown" });

    // The resolved settings, at debug. This is the first thing an agent reading
    // a log needs and cannot see from the outside: which level the run is at,
    // and which file that level is going to.
    log.debug("logging at {s} to {s}", .{
        @tagName(sink.level),
        if (sink.logPath().len == 0) "stderr only" else sink.logPath(),
    });

    // `--print-log-path` answers before anything else can go wrong and before a
    // window exists, so a headless test driver can rely on it. When there is no
    // file to name, it says so rather than printing an empty line that a script
    // would treat as a path.
    if (options.print_log_path) {
        if (sink.logPath().len == 0) {
            try writeStdout(init.io, "(no log file: logging to stderr only)\n");
        } else {
            try writeStdout(init.io, sink.logPath());
            try writeStdout(init.io, "\n");
        }
        return 0;
    }

    const resolved = optionsForRun(options);
    log.debug("window {d}x{d} logical, {s}, {s}", .{
        resolved.run.width,
        resolved.run.height,
        if (resolved.run.hidden) "hidden" else "visible",
        if (resolved.run.run_ms) |_| "a run budget" else "run until closed",
    });
    return runApp(init, resolved);
}

/// Open the window, load the GPU bindings, and run until the window closes.
///
/// Everything taken here is given back in the reverse order: the app first, then
/// the window and its context, then SDL. A run that ends this way has nothing of
/// Conduit's left alive and nothing of Conduit's left allocated.
fn driverTestEndpoint(io: Io, buffer: []u8) ![]const u8 {
    var id_buffer: [path_capacity]u8 = undefined;
    const id = try generateRunId(io, &id_buffer);
    return if (builtin.os.tag == .windows)
        std.fmt.bufPrint(buffer, "\\\\.\\pipe\\conduit-{s}", .{id})
    else
        std.fmt.bufPrint(buffer, "{s}{c}driver-{s}.sock", .{ fallback_log_dir, std.fs.path.sep, id });
}

/// Make a directory name unique to this process run. The worker that writes
/// the first screenshot creates it; startup performs no artifact filesystem IO.
fn generatedArtifactDir(io: Io, base: []const u8, buffer: []u8) ![]const u8 {
    var id_buffer: [path_capacity]u8 = undefined;
    const id = try generateRunId(io, &id_buffer);
    return std.fmt.bufPrint(buffer, "{s}{c}conduit-artifacts-{s}", .{ base, std.fs.path.sep, id });
}

fn runApp(init: std.process.Init, initial_options: Options) !u8 {
    var options = initial_options;
    var driver_endpoint_buffer: [path_capacity]u8 = undefined;
    if (options.run.driver_test and options.run.test_driver_endpoint == null) {
        options.run.test_driver_endpoint = try driverTestEndpoint(init.io, &driver_endpoint_buffer);
    }
    var artifact_dir_buffer: [path_capacity]u8 = undefined;
    if (options.run.test_driver_endpoint != null and options.run.test_artifact_dir == null) {
        options.run.test_artifact_dir = try generatedArtifactDir(init.io, options.dir, &artifact_dir_buffer);
    }
    const env = processEnv(init);
    try platform.setAppMetadata(.{
        .name = app_name,
        .version = version,
        .identifier = app_identifier,
    });
    // The clipboard check writes fixtures to the clipboard and the primary
    // selection. Pinned to `offscreen`, those are SDL's process-local copies;
    // on any other driver they would be the display's — someone's real
    // clipboard — so a run that cannot be pinned refuses to start.
    if (options.run.clipboard_test) {
        if (!platform.forceVideoDriver("offscreen")) return error.ClipboardTestDriverNotPinned;
    }
    var window = platform.Window.create(.{
        .title = window_title,
        .logical = .{ .width = options.run.width, .height = options.run.height },
        .fixed_scale = if (options.run.scale) |factor| platform.Scale.fromPlatform(factor) else null,
        .hidden = options.run.hidden,
    }) catch |err| switch (err) {
        // No display server, or no video driver will start. A windowed app on a
        // machine with no window system has nothing to draw in: it says so and
        // leaves, so `zig build run` still works on a headless development box. A
        // run that was asked to prove something does not get that answer — a check
        // that cannot run must fail rather than pass quietly.
        error.VideoUnavailable => {
            if (options.run.self_test or options.run.grid_test or options.run.scroll_test or
                options.run.mouse_test or options.run.clipboard_test or options.run.ui_test or
                options.run.ime_test or options.run.sidebar_test or options.run.tabs_test or options.run.panes_test or
                options.run.scratchpad_test or options.run.palette_test or options.run.workspaces_test or
                options.run.links_test or options.run.search_test or options.run.menu_test or
                options.run.driver_test) return err;
            var buffer: [256]u8 = undefined;
            log.warn(
                "no usable display ({s}): there is no window to draw in. Set DISPLAY, or run under xvfb-run",
                .{platform.lastError(&buffer)},
            );
            return 0;
        },
        else => return err,
    };
    defer window.deinit();
    const runtime = window.runtimeInfo();
    log.info("window backend {s}, high-pixel-density {s}", .{
        runtime.video_backend orelse "unknown",
        if (runtime.high_pixel_density) "enabled" else "disabled",
    });
    if (runtime.pixel_density) |density| {
        log.info("window reports {d:.2} physical pixels per logical pixel", .{density});
    } else {
        log.debug("the window backend did not report a pixel density", .{});
    }
    if (runtime.logical_size) |logical| {
        if (runtime.pixel_size) |pixels| {
            log.info("window geometry {d}x{d} logical, {d}x{d} pixels", .{
                logical.width,
                logical.height,
                pixels.width_px,
                pixels.height_px,
            });
        } else {
            log.debug("window geometry {d}x{d} logical; pixel size unavailable", .{
                logical.width,
                logical.height,
            });
        }
    } else if (runtime.pixel_size) |pixels| {
        log.debug("window geometry {d}x{d} pixels; logical size unavailable", .{
            pixels.width_px,
            pixels.height_px,
        });
    } else {
        log.debug("the window backend did not report window geometry", .{});
    }
    if (options.run.clipboard_test) {
        const driver = platform.videoDriverName() orelse "";
        if (!std.mem.eql(u8, driver, "offscreen")) {
            log.err("--clipboard-test refuses to run on the {s} driver: its clipboard is the display's", .{driver});
            return error.ClipboardTestDriverNotPinned;
        }
    }

    try render.load();

    var out_buffer: [4096]u8 = undefined;
    var out_file = File.stdout().writerStreaming(init.io, &out_buffer);
    const out = &out_file.interface;

    // The grid check builds its own surfaces, faces and terminal: it has to
    // render the same screen at two display scales, which a window at one scale
    // cannot do, and a check that shares the app's state measures the app's
    // state rather than the grid.
    if (options.run.grid_test) {
        const status = try gridTest(init.io, init.gpa, env, options.run.font_family, out);
        out_file.interface.flush() catch {};
        return status;
    }

    const app = try App.init(init.io, env, init.gpa, &window, options);
    defer app.destroy();
    try app.syncTextInput();

    // A check's status is the run's status: `--scroll-test` and `--mouse-test`
    // exit non-zero when a check failed, which is what a test script reads.
    var check_status: u8 = 0;
    if (options.run.driver_test) {
        check_status = try driverTest(app, init.io, out, options.run.test_driver_endpoint.?);
    } else if (options.run.self_test) {
        try selfTest(app, init.io, out);
    } else if (options.run.scroll_test) {
        check_status = try scrollTest(app, init.io, out);
    } else if (options.run.mouse_test) {
        check_status = try mouseTest(app, init.io, out);
    } else if (options.run.clipboard_test) {
        check_status = try clipboardTest(app, init.io, out);
    } else if (options.run.ui_test) {
        check_status = try uiTest(app, init.io, out);
    } else if (options.run.ime_test) {
        check_status = try imeTest(app, init.io, out);
    } else if (options.run.sidebar_test) {
        check_status = try sidebarTest(app, init.io, out);
    } else if (options.run.tabs_test) {
        check_status = try tabsTest(app, init.io, out);
    } else if (options.run.panes_test) {
        check_status = try panesTest(app, init.io, out);
    } else if (options.run.scratchpad_test) {
        check_status = try scratchpadTest(app, init.io, out);
    } else if (options.run.palette_test) {
        check_status = try paletteTest(app, init.io, out);
    } else if (options.run.workspaces_test) {
        check_status = try workspacesTest(app, init.io, out);
    } else if (options.run.links_test) {
        check_status = try linksTest(app, init.io, out);
    } else if (options.run.search_test) {
        check_status = try searchTest(app, init.io, out);
    } else if (options.run.menu_test) {
        check_status = try menuTest(app, init.io, out);
    } else {
        try app.run(init.io, runDeadline(init.io, options.run.run_ms));
    }
    out_file.interface.flush() catch {};

    // The screenshot is the surface as the run left it, through the same
    // readback a `--self-test` capture uses, so what the file holds is what the
    // window was showing.
    if (options.run.screenshot) |path| {
        const pixels = try app.capture();
        try writePngOffThread(init.gpa, init.io, path, pixels, app.size);
        log.info("screenshot written to {s} ({d}x{d})", .{ path, app.size.width, app.size.height });
    }

    log.info("conduit leaving after {d} frames", .{app.scheduler.frames});
    return check_status;
}

/// Scratch for the startup line's target name. `main` owns the process, so a
/// buffer it never re-enters does not need to be threaded through.
var target_buf: [64]u8 = undefined;

/// The arguments as a slice, `argv[0]` first, exactly as the OS gave them.
fn collectArgs(allocator: Allocator, args: std.process.Args) ![]const []const u8 {
    var iterator = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iterator.deinit();

    var collected: std.ArrayList([]const u8) = .empty;
    while (iterator.next()) |arg| try collected.append(allocator, arg);
    return collected.items;
}

fn writeStdout(io: Io, text: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var out = File.stdout().writerStreaming(io, &buffer);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

fn writeStderrText(text: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    var out = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    try out.writer.writeAll(text);
    try out.writer.flush();
}

/// Describe the build target as `<arch>-<os>` into `buf`, for example
/// `x86_64-linux`. Only the two parts that are true on every target are
/// reported, so the startup line never claims an ABI it does not know.
pub fn buildTarget(buf: []u8) std.fmt.BufPrintError![]const u8 {
    return std.fmt.bufPrint(buf, "{s}-{s}", .{
        @tagName(builtin.target.cpu.arch),
        @tagName(builtin.target.os.tag),
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "buildTarget names the architecture and the operating system" {
    var buf: [64]u8 = undefined;
    const got = try buildTarget(&buf);

    try std.testing.expectEqualStrings(
        @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag),
        got,
    );
}

const test_env = struct {
    vars: []const [2][]const u8,

    fn get(ctx: *const anyopaque, key: []const u8) ?[]const u8 {
        const self: *const @This() = @ptrCast(@alignCast(ctx));
        for (self.vars) |pair| {
            if (std.mem.eql(u8, pair[0], key)) return pair[1];
        }
        return null;
    }

    fn source(self: *const @This()) EnvSource {
        return .{ .ctx = self, .getFn = get };
    }
};

test "parseLevel accepts every level name and the two long spellings" {
    try std.testing.expectEqual(Level.err, try parseLevel("err"));
    try std.testing.expectEqual(Level.err, try parseLevel("error"));
    try std.testing.expectEqual(Level.err, try parseLevel("ERROR"));
    try std.testing.expectEqual(Level.warn, try parseLevel("warn"));
    try std.testing.expectEqual(Level.warn, try parseLevel("warning"));
    try std.testing.expectEqual(Level.info, try parseLevel("info"));
    try std.testing.expectEqual(Level.debug, try parseLevel("debug"));
    try std.testing.expectEqual(Level.debug, try parseLevel("DeBuG"));
}

test "parseLevel rejects anything that is not a level" {
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("trace"));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel(""));
    try std.testing.expectError(error.InvalidLogLevel, parseLevel("info "));
}

test "no flag and no environment gives the built-in default level" {
    const env = test_env{ .vars = &.{} };
    const options = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expectEqual(default_level, options.level);
    try std.testing.expect(options.file == null);
    try std.testing.expectEqualStrings(fallback_log_dir, options.dir);
}

test "the environment sets the level when no flag does" {
    const env = test_env{ .vars = &.{.{ level_env, "debug" }} };
    const options = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expectEqual(Level.debug, options.level);
}

test "a flag beats the environment for every setting" {
    const env = test_env{ .vars = &.{
        .{ level_env, "debug" },
        .{ file_env, "/from/env.log" },
        .{ dir_env, "/from/env" },
    } };
    const options = try parseArgs(&.{
        "conduit",
        "--log-level=warn",
        "--log-file=/from/flag.log",
        "--log-dir=/from/flag",
    }, env.source());

    try std.testing.expectEqual(Level.warn, options.level);
    try std.testing.expectEqualStrings("/from/flag.log", options.file.?);
    try std.testing.expectEqualStrings("/from/flag", options.dir);
}

test "an environment-only configuration keeps every environment value" {
    const env = test_env{ .vars = &.{
        .{ level_env, "warn" },
        .{ file_env, "/from/env.log" },
        .{ dir_env, "/from/env" },
    } };
    const options = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expectEqual(Level.warn, options.level);
    try std.testing.expectEqualStrings("/from/env.log", options.file.?);
    try std.testing.expectEqualStrings("/from/env", options.dir);
}

test "an unknown flag or a bad value is a config error, never a panic" {
    const env = test_env{ .vars = &.{} };
    try std.testing.expectError(error.UnknownFlag, parseArgs(&.{ "conduit", "--turbo" }, env.source()));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--log-level" }, env.source()));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--log-level=--dir" }, env.source()));
    try std.testing.expectError(error.InvalidLogLevel, parseArgs(&.{ "conduit", "--log-level=loud" }, env.source()));
}

test "a flag value may follow the flag or use an equals sign" {
    const env = test_env{ .vars = &.{} };
    const spaced = try parseArgs(&.{ "conduit", "--log-level", "err", "--log-dir", "/tmp/x" }, env.source());
    try std.testing.expectEqual(Level.err, spaced.level);
    try std.testing.expectEqualStrings("/tmp/x", spaced.dir);

    const equals = try parseArgs(&.{ "conduit", "--log-level=err", "--log-dir=/tmp/x" }, env.source());
    try std.testing.expectEqual(spaced.level, equals.level);
    try std.testing.expectEqualStrings(spaced.dir, equals.dir);
}

test "an empty environment variable counts as unset" {
    const env = test_env{ .vars = &.{
        .{ level_env, "" },
        .{ dir_env, "" },
    } };
    const options = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expectEqual(default_level, options.level);
    try std.testing.expectEqualStrings(fallback_log_dir, options.dir);
}

test "the platform temporary directory is used when no directory is named" {
    const env = test_env{ .vars = &.{.{ "TMPDIR", "/tmp/from-tmpdir" }} };
    const options = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expectEqualStrings("/tmp/from-tmpdir", options.dir);
}

test "the explicit log directory beats the temporary one" {
    const env = test_env{ .vars = &.{
        .{ "TMPDIR", "/tmp/from-tmpdir" },
        .{ dir_env, "/explicit" },
    } };
    const options = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expectEqualStrings("/explicit", options.dir);
}

test "--clipboard-test is documented and runs its fixed PTY peer" {
    const env = test_env{ .vars = &.{} };
    const options = try parseArgs(&.{ "conduit", "--clipboard-test" }, env.source());
    try std.testing.expect(options.run.clipboard_test);
    // Even with --no-child: a paste is only proved by what a program reads.
    const no_child = try parseArgs(&.{ "conduit", "--clipboard-test", "--no-child" }, env.source());
    try std.testing.expect(wantsChild(no_child));
    try std.testing.expect(!wantsChild(try parseArgs(&.{ "conduit", "--mouse-test" }, env.source())));
    try std.testing.expect(std.mem.indexOf(u8, usage, "--clipboard-test") != null);
    // The child it runs is the fixed script, never the user's shell.
    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), options);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(clipboard_test_script, spec.argv[2]);
}

test "--ime-test is documented and runs its fixed PTY peer" {
    const env = test_env{ .vars = &.{} };
    const options = try parseArgs(&.{ "conduit", "--ime-test", "--no-child" }, env.source());
    try std.testing.expect(options.run.ime_test);
    try std.testing.expect(wantsChild(options));
    try std.testing.expect(std.mem.indexOf(u8, usage, "--ime-test") != null);
    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), options);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(ime_test_script, spec.argv[2]);
}

test "--tabs-test is documented and runs its fixed PTY peers" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--tabs-test", "--no-child" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.tabs_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--tabs-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(sidebarEnabled(resolved));
    try std.testing.expect(sidebarStartsVisible(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(tabs_test_script, spec.argv[2]);
}

test "--panes-test is documented and runs its fixed PTY peers" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--panes-test", "--no-child" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.panes_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--panes-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(sidebarEnabled(resolved));
    try std.testing.expect(sidebarStartsVisible(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(panes_test_script, spec.argv[2]);
}

test "--scratchpad-test is documented and its shell spec is independently interactive" {
    const env = test_env{ .vars = &.{
        .{ "SHELL", "/bin/false" },
        .{ "PATH", "/usr/bin:/bin" },
    } };
    const parsed = try parseArgs(&.{ "conduit", "--scratchpad-test", "--command=never-copy-this" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.scratchpad_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--scratchpad-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(resolved.run.no_child);
    try std.testing.expect(!wantsChild(resolved));

    var spec = try ChildSpec.buildInteractive(
        std.testing.allocator,
        std.testing.io,
        env.source(),
        false,
        "/bin/sh",
    );
    defer spec.deinit();
    try std.testing.expectEqual(@as(usize, 1), spec.argv.len);
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    for (spec.argv) |argument| {
        try std.testing.expect(std.mem.indexOf(u8, argument, "never-copy-this") == null);
        try std.testing.expect(std.mem.indexOf(u8, argument, tabs_test_script) == null);
        try std.testing.expect(std.mem.indexOf(u8, argument, panes_test_script) == null);
        try std.testing.expect(std.mem.indexOf(u8, argument, palette_test_script) == null);
        try std.testing.expect(std.mem.indexOf(u8, argument, workspaces_test_script) == null);
        try std.testing.expect(std.mem.indexOf(u8, argument, links_test_script) == null);
        try std.testing.expect(std.mem.indexOf(u8, argument, menu_test_script) == null);
    }
}

test "--palette-test owns a fixed real-child production viewport" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--palette-test" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.palette_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--palette-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(sidebarEnabled(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(palette_test_script, spec.argv[2]);
}

test "--workspaces-test owns a fixed real-child production viewport" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--workspaces-test", "--no-child" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.workspaces_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--workspaces-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(sidebarEnabled(resolved));
    try std.testing.expect(sidebarStartsVisible(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(workspaces_test_script, spec.argv[2]);
}

test "--links-test owns a fixed real-child terminal viewport" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--links-test", "--no-child" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.links_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--links-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(!sidebarEnabled(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(links_test_script, spec.argv[2]);
}

test "--search-test owns a fixed real-child terminal viewport" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--search-test", "--no-child" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.search_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--search-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(!sidebarEnabled(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(search_test_script, spec.argv[2]);
}

test "--menu-test owns a fixed real-child terminal viewport" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--menu-test", "--no-child" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.menu_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--menu-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--right-click=<menu|paste>") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(wantsChild(resolved));
    try std.testing.expect(!sidebarEnabled(resolved));

    var spec = try ChildSpec.build(std.testing.allocator, std.testing.io, env.source(), resolved);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    try std.testing.expectEqualStrings(menu_test_script, spec.argv[2]);
}

test "the right-click setting is a validated session layer over the built-in default" {
    const env = test_env{ .vars = &.{} };
    const plain = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expect(plain.run.right_click == null);
    try std.testing.expectEqual(config.RightClick.menu, config.Layer.resolve(config.RightClick, config.RightClick.built_in, null, plain.run.right_click));

    const paste = try parseArgs(&.{ "conduit", "--right-click=paste" }, env.source());
    try std.testing.expectEqual(@as(?config.RightClick, .paste), paste.run.right_click);
    try std.testing.expectEqual(config.RightClick.paste, config.Layer.resolve(config.RightClick, config.RightClick.built_in, null, paste.run.right_click));
    const split = try parseArgs(&.{ "conduit", "--right-click", "menu" }, env.source());
    try std.testing.expectEqual(@as(?config.RightClick, .menu), split.run.right_click);

    try std.testing.expectError(error.InvalidRightClick, parseArgs(&.{ "conduit", "--right-click=nope" }, env.source()));
    try std.testing.expectError(error.InvalidRightClick, parseArgs(&.{ "conduit", "--right-click=Paste" }, env.source()));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--right-click" }, env.source()));
}

test "context menu rows depend only on selection and link presence" {
    var storage: [context_menu_max_items]ContextMenuItem = undefined;
    const bare = contextMenuItems(false, false, &storage);
    try std.testing.expectEqual(@as(usize, 4), bare.len);
    try std.testing.expectEqualStrings("context-menu.paste", bare[0].id);
    try std.testing.expectEqualStrings(clipboard_paste_action, bare[0].action);
    try std.testing.expectEqualStrings("context-menu.split-right", bare[1].id);
    try std.testing.expectEqualStrings(pane_split_action, bare[1].action);
    try std.testing.expectEqualStrings("context-menu.split-down", bare[2].id);
    try std.testing.expectEqualStrings(pane_split_action, bare[2].action);
    try std.testing.expectEqualStrings("context-menu.search", bare[3].id);
    try std.testing.expectEqualStrings(search_open_action, bare[3].action);

    const selected = contextMenuItems(true, false, &storage);
    try std.testing.expectEqual(@as(usize, 5), selected.len);
    try std.testing.expectEqualStrings("context-menu.copy", selected[0].id);
    try std.testing.expectEqualStrings(clipboard_copy_action, selected[0].action);
    try std.testing.expectEqualStrings("context-menu.paste", selected[1].id);

    const linked = contextMenuItems(false, true, &storage);
    try std.testing.expectEqual(@as(usize, 5), linked.len);
    try std.testing.expectEqualStrings("context-menu.open-link", linked[1].id);
    try std.testing.expectEqualStrings(terminal_open_link_action, linked[1].action);

    const full = contextMenuItems(true, true, &storage);
    try std.testing.expectEqual(context_menu_max_items, full.len);
    for (full) |item| {
        try std.testing.expect(std.mem.startsWith(u8, item.id, "context-menu."));
        try std.testing.expect(item.label.len + 4 <= context_menu_width);
    }
}

test "context menu bounds anchor at the pointer cell and stay inside the canvas" {
    const canvas: ui.Rect = .{ .x = 0, .y = 0, .width = 80, .height = 24 };
    const anchored = contextMenuBounds(10, 5, 4, canvas).?;
    try std.testing.expectEqual(@as(u32, 10), anchored.x);
    try std.testing.expectEqual(@as(u32, 5), anchored.y);
    try std.testing.expectEqual(context_menu_width, anchored.width);
    try std.testing.expectEqual(@as(u32, 6), anchored.height);

    const clamped = contextMenuBounds(79, 23, 6, canvas).?;
    try std.testing.expectEqual(@as(u32, 80 - context_menu_width), clamped.x);
    try std.testing.expectEqual(@as(u32, 24 - 8), clamped.y);

    try std.testing.expect(contextMenuBounds(0, 0, 4, .{ .x = 0, .y = 0, .width = context_menu_width - 1, .height = 24 }) == null);
    try std.testing.expect(contextMenuBounds(0, 0, 4, .{ .x = 0, .y = 0, .width = 80, .height = 5 }) == null);
}

test "built-in checks isolate the scratchpad from the user shell" {
    try std.testing.expect(!usesDeterministicScratchpad(.{}));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .ui_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .clipboard_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .scratchpad_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .palette_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .workspaces_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .links_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .search_test = true } }));
    try std.testing.expect(usesDeterministicScratchpad(.{ .run = .{ .menu_test = true } }));
    try std.testing.expect(!usesDeterministicScratchpad(.{ .run = .{ .test_driver_endpoint = "/tmp/conduit.sock" } }));
}

test "pane semantic ids and pointer clipping reject malformed boundaries" {
    const pane = App.workspaceEntityForSemantic("workspace.7.pane.1", "pane").?;
    try std.testing.expectEqual(@as(workspace.WorkspaceKey, @enumFromInt(7)), pane.key);
    try std.testing.expectEqual(@as(u32, 1), pane.ordinal);
    const divider = App.workspaceEntityForSemantic("workspace.7.divider.9", "divider").?;
    try std.testing.expectEqual(@as(workspace.WorkspaceKey, @enumFromInt(7)), divider.key);
    try std.testing.expectEqual(@as(u32, 9), divider.ordinal);
    try std.testing.expect(App.workspaceEntityForSemantic("workspace.7.pane.0", "pane") == null);
    try std.testing.expect(App.workspaceEntityForSemantic("workspace.7.pane.no", "pane") == null);
    try std.testing.expect(App.workspaceEntityForSemantic("workspace.8.pane.1", "divider") == null);
    try std.testing.expect(App.workspaceEntityForSemantic("pane.1", "pane") == null);
    try std.testing.expectEqual(@as(f32, 0), App.clippedPaneCoordinate(-4, 20));
    try std.testing.expectEqual(@as(f32, 19), App.clippedPaneCoordinate(40, 20));
    try std.testing.expectEqual(@as(f32, 0), App.clippedPaneCoordinate(4, 0));
}

test "terminal link byte spans map only whole UTF-8 terminal cells" {
    var terminal: term.Terminal = undefined;
    try terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 12, .rows = 2 });
    defer terminal.deinit(std.testing.allocator);

    terminal.feed("é界x");
    try terminal.refresh(std.testing.allocator);
    try std.testing.expectEqual(
        TerminalLinkCellBounds{ .col = 1, .width = 2 },
        App.terminalLinkCellBounds(&terminal, 0, .{ .start = 2, .end = 5 }).?,
    );
    try std.testing.expectEqual(
        TerminalLinkCellBounds{ .col = 3, .width = 1 },
        App.terminalLinkCellBounds(&terminal, 0, .{ .start = 5, .end = 6 }).?,
    );
    try std.testing.expect(App.terminalLinkCellBounds(&terminal, 0, .{ .start = 1, .end = 5 }) == null);
}

test "terminal link fingerprints are stable bounded and domain separated" {
    const baseline = terminalLinkFingerprint(.url, "https://example.test/path", null, null);
    const repeated = terminalLinkFingerprint(.url, "https://example.test/path", null, null);
    try std.testing.expectEqualSlices(u8, baseline[0..], repeated[0..]);

    const encoded = std.fmt.bytesToHex(baseline, .lower);
    try std.testing.expectEqualStrings("2b56e67985cabe0f5192c7d48d436990", encoded[0..]);
    try std.testing.expectEqual(@as(usize, terminal_link_fingerprint_bytes * 2), encoded.len);

    const other_target = terminalLinkFingerprint(.url, "https://example.test/other", null, null);
    const other_kind = terminalLinkFingerprint(.file, "https://example.test/path", null, null);
    const other_line = terminalLinkFingerprint(.file, "https://example.test/path", 42, null);
    const other_column = terminalLinkFingerprint(.file, "https://example.test/path", 42, 7);
    try std.testing.expect(!std.mem.eql(u8, baseline[0..], other_target[0..]));
    try std.testing.expect(!std.mem.eql(u8, baseline[0..], other_kind[0..]));
    try std.testing.expect(!std.mem.eql(u8, other_kind[0..], other_line[0..]));
    try std.testing.expect(!std.mem.eql(u8, other_line[0..], other_column[0..]));

    var semantic_storage: [terminal_link_semantic_capacity]u8 = undefined;
    const largest_semantic = try std.fmt.bufPrint(
        &semantic_storage,
        "workspace.{d}.session.{d}.terminal-link.{d}.{d}.{s}.{d}",
        .{
            std.math.maxInt(u64),
            std.math.maxInt(u32),
            std.math.maxInt(u16),
            std.math.maxInt(u16),
            encoded[0..],
            link.default_max_target_bytes,
        },
    );
    try std.testing.expect(largest_semantic.len <= terminal_link_semantic_capacity);
}

test "file reference argv resolves against the tracked cwd without a shell" {
    const allocator = std.testing.allocator;
    const with_line = try buildFileReferenceArgv(allocator, "./notes.txt", 3, "/srv/work");
    defer freeEntries(allocator, with_line);
    try std.testing.expectEqual(@as(usize, 4), with_line.len);
    try std.testing.expectEqualStrings("vi", with_line[0]);
    try std.testing.expectEqualStrings("+3", with_line[1]);
    try std.testing.expectEqualStrings("--", with_line[2]);
    try std.testing.expectEqualStrings("/srv/work/notes.txt", with_line[3]);

    const without_line = try buildFileReferenceArgv(allocator, "src/main.zig", null, "/srv/work/");
    defer freeEntries(allocator, without_line);
    try std.testing.expectEqual(@as(usize, 3), without_line.len);
    try std.testing.expectEqualStrings("vi", without_line[0]);
    try std.testing.expectEqualStrings("--", without_line[1]);
    try std.testing.expectEqualStrings("/srv/work/src/main.zig", without_line[2]);

    // A column is identity only; vi receives the line alone.
    const with_column = try buildFileReferenceArgv(allocator, "../lib/a.zig", 12, "/srv/work");
    defer freeEntries(allocator, with_column);
    try std.testing.expectEqual(@as(usize, 4), with_column.len);
    try std.testing.expectEqualStrings("+12", with_column[1]);
    try std.testing.expectEqualStrings("/srv/work/../lib/a.zig", with_column[3]);

    const absolute = try buildFileReferenceArgv(allocator, "/etc/hosts", 7, "/ignored");
    defer freeEntries(allocator, absolute);
    try std.testing.expectEqualStrings("/etc/hosts", absolute[3]);
    for (absolute) |entry| try std.testing.expect(std.mem.indexOfScalar(u8, entry, ' ') == null);
}

test "file reference argv rejects unsafe and overlong text" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsafePath, buildFileReferenceArgv(allocator, "a\nb.zig", 1, "/srv"));
    try std.testing.expectError(error.UnsafePath, buildFileReferenceArgv(allocator, "a\x1bb.zig", 1, "/srv"));
    try std.testing.expectError(error.UnsafePath, buildFileReferenceArgv(allocator, "ok.zig", 1, "/srv\x7f"));
    try std.testing.expectError(error.UnsafePath, buildFileReferenceArgv(allocator, "ok.zig", 1, ""));
    try std.testing.expectError(error.UnsafePath, buildFileReferenceArgv(allocator, "././", 1, "/srv"));
    try std.testing.expectError(error.UnsafePath, buildFileReferenceArgv(allocator, &.{ 0xff, 'a' }, 1, "/srv"));
    const long_cwd = [_]u8{'x'} ** file_reference_path_max_bytes;
    try std.testing.expectError(error.PathTooLong, buildFileReferenceArgv(allocator, "a.zig", 1, &long_cwd));
}

test "file reference labels are the bounded final path component" {
    try std.testing.expectEqualStrings("notes.txt", fileReferenceLabel("./notes.txt"));
    try std.testing.expectEqualStrings("main.zig", fileReferenceLabel("/srv/work/src/main.zig"));
    try std.testing.expectEqualStrings("main.zig", fileReferenceLabel("C:\\src\\main.zig"));
    try std.testing.expectEqualStrings("Makefile", fileReferenceLabel("Makefile"));
    const long_name = [_]u8{'n'} ** (file_reference_label_max_bytes + 20);
    try std.testing.expectEqual(file_reference_label_max_bytes, fileReferenceLabel(&long_name).len);
    const multibyte = "é" ** (file_reference_label_max_bytes / 2 + 2);
    const cut = fileReferenceLabel(multibyte);
    try std.testing.expect(cut.len <= file_reference_label_max_bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "workspace paths are normalized and named lexically" {
    try std.testing.expectEqualStrings("/", App.normalizedWorkspaceDirectory(" // "));
    try std.testing.expectEqualStrings("/srv/project", App.normalizedWorkspaceDirectory(" /srv/project/// "));
    try std.testing.expectEqualStrings("C:\\", App.normalizedWorkspaceDirectory("C:\\\\"));
    try std.testing.expectEqualStrings("/", App.workspaceBaseName("/"));
    try std.testing.expectEqualStrings("project", App.workspaceBaseName("/srv/project"));
    try std.testing.expectEqualStrings("project", App.workspaceBaseName("C:\\src\\project"));
}

test "an OSC 52 selector names the native clipboard it reaches, and no other" {
    try std.testing.expectEqual(ClipboardTarget.standard, try nativeTarget(.standard));
    if (platform.primary_selection_supported) {
        try std.testing.expectEqual(ClipboardTarget.primary, try nativeTarget(.primary));
        try std.testing.expectEqual(ClipboardTarget.primary, try nativeTarget(.selection));
    } else {
        try std.testing.expectError(error.Unsupported, nativeTarget(.primary));
        try std.testing.expectError(error.Unsupported, nativeTarget(.selection));
    }
    // A platform failure reaches `term` as a failure it can answer, never as
    // a success.
    try std.testing.expectEqual(error.Unavailable, accessError(error.ClipboardReadFailed));
    try std.testing.expectEqual(error.Unavailable, accessError(error.ClipboardWriteFailed));
    try std.testing.expectEqual(error.InvalidText, accessError(error.InvalidText));
    try std.testing.expectEqual(error.PayloadTooLarge, accessError(error.PayloadTooLarge));
}

test "--print-log-path and --help are recognised without a window" {
    const env = test_env{ .vars = &.{} };
    const print_only = try parseArgs(&.{ "conduit", "--print-log-path" }, env.source());
    try std.testing.expect(print_only.print_log_path);
    try std.testing.expect(!print_only.help);

    const help = try parseArgs(&.{ "conduit", "--help" }, env.source());
    try std.testing.expect(help.help);
    try std.testing.expect(!help.print_log_path);

    const print_version = try parseArgs(&.{ "conduit", "--version" }, env.source());
    try std.testing.expect(print_version.print_version);
    try std.testing.expect(!print_version.help);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--version") != null);
    _ = try std.SemanticVersion.parse(version);
}

test "run ids are unique per run for the same instant" {
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    const first = try runIdPattern(&a, "20261004T213800Z", .{ 0x11, 0x22, 0x33 });
    const second = try runIdPattern(&b, "20261004T213800Z", .{ 0x11, 0x22, 0x34 });
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqualStrings("run-20261004T213800Z-112233", first);
}

test "the stamp is UTC and zero-padded" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("19700101T000000Z", try stampPattern(&buf, 0));
    try std.testing.expectEqualStrings("20210704T144033Z", try stampPattern(&buf, 1625409633));
    // A clock outside any plausible date is clamped, never looped over.
    try std.testing.expectEqualStrings("99991231T235959Z", try stampPattern(&buf, max_stamp_seconds));
    try std.testing.expectEqualStrings("19700101T000000Z", try stampPattern(&buf, -1));
}

test "a crash report path sits beside the log it explains" {
    var buf: [path_capacity]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/tmp/conduit/run-1.crash.txt",
        try crashPathFor(&buf, "/tmp/conduit/run-1.log"),
    );
    try std.testing.expectEqualStrings(
        "/tmp/conduit/conduit.crash.txt",
        try crashPathFor(&buf, "/tmp/conduit/conduit"),
    );
}

test "the log file and the crash report share a directory" {
    var joined: [path_capacity]u8 = undefined;
    var crash: [path_capacity]u8 = undefined;
    const log_path = try joinPath(&joined, "/tmp/conduit", "run-1.log");
    const crash_path = try crashPathFor(&crash, log_path);
    try std.testing.expectEqualStrings(std.fs.path.dirname(log_path).?, std.fs.path.dirname(crash_path).?);
}

/// The path of a file inside `tmp`, relative to the working directory the
/// test binary runs in. `std.testing.tmpDir` puts its directory under
/// `.zig-cache/tmp`, so a bare `sub_path` is not enough to reach it.
fn tmpPath(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var dir_buffer: [path_capacity]u8 = undefined;
    const dir = try joinPath(&dir_buffer, ".zig-cache/tmp", tmp.sub_path[0..]);
    return joinPath(buffer, dir, name);
}

/// Install a sink writing `<tmp>/conduit.log` at `level`. The caller owns the
/// sink and must call `sink.deinit()`; the resolved path is `sink.logPath()`.
fn installInTmp(tmp: *std.testing.TmpDir, level: Level) !void {
    var path_buffer: [path_capacity]u8 = undefined;
    const path = try tmpPath(tmp, "conduit.log", &path_buffer);
    try sink.install(std.testing.io, .{ .level = level, .file = path });
}

/// The contents of `<tmp>/<name>`, for asserting on what was written.
fn readInTmp(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    var path_buffer: [path_capacity]u8 = undefined;
    const path = try tmpPath(tmp, name, &path_buffer);
    return Dir.cwd().readFile(std.testing.io, path, buffer);
}

test "the sink writes stderr and the log file, filtered by the resolved level" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try installInTmp(&tmp, .warn);
    defer sink.deinit();
    try std.testing.expectEqual(Level.warn, sink.level);
    try std.testing.expect(std.mem.endsWith(u8, sink.logPath(), "conduit.log"));

    emit(.err, .app, "an error line", .{});
    emit(.warn, .app, "a warning line", .{});
    emit(.info, .app, "an info line", .{});
    emit(.debug, .app, "a debug line", .{});
    if (sink.file) |*file| file.interface.flush() catch {};

    var buffer: [8 * 1024]u8 = undefined;
    const contents = try readInTmp(&tmp, "conduit.log", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "an error line") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "a warning line") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "an info line") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "a debug line") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "error(app): ") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Z error(app): ") != null);
}

test "the log level raises what the sink accepts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try installInTmp(&tmp, .debug);
    defer sink.deinit();

    emit(.err, .app, "an error line", .{});
    emit(.warn, .app, "a warning line", .{});
    emit(.info, .app, "an info line", .{});
    emit(.debug, .app, "a debug line", .{});
    if (sink.file) |*file| file.interface.flush() catch {};

    var buffer: [8 * 1024]u8 = undefined;
    const contents = try readInTmp(&tmp, "conduit.log", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "an error line") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "a warning line") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "an info line") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "a debug line") != null);
}

test "the in-memory log tail is bounded and readable without the log file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try installInTmp(&tmp, .debug);
    defer sink.deinit();
    emit(.info, .app, "driver-visible-log-line", .{});

    var storage: [256]u8 = undefined;
    const tail = sink.copyTail(&storage);
    try std.testing.expect(std.mem.indexOf(u8, tail, "driver-visible-log-line") != null);
    try std.testing.expect(tail.len <= storage.len);
}

test "sensitive content is not written above debug, whatever the scope is asked for" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try installInTmp(&tmp, .info);

    sensitiveLog("clipboard: {s}", .{"hunter2"});
    emit(.info, .sensitive, "an agent prompt", .{});
    emit(.err, .sensitive, "a credential", .{});
    if (sink.file) |*file| file.interface.flush() catch {};

    var buffer: [8 * 1024]u8 = undefined;
    const contents = try readInTmp(&tmp, "conduit.log", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "an agent prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "a credential") == null);
}

test "sensitive content is written at debug level, tagged as sensitive" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try installInTmp(&tmp, .debug);
    defer sink.deinit();
    sensitiveLog("clipboard: {s}", .{"hunter2"});
    if (sink.file) |*file| file.interface.flush() catch {};

    var buffer: [8 * 1024]u8 = undefined;
    const contents = try readInTmp(&tmp, "conduit.log", &buffer);
    try std.testing.expect(std.mem.indexOf(u8, contents, "hunter2") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "debug(sensitive): ") != null);
}

test "a crash report carries the panic message, a stack trace and the log tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a log the way the app writes one, so the tail the report carries
    // is a real tail of a real log rather than a hand-made string.
    var log_path_buffer: [path_capacity]u8 = undefined;
    const log_path = try tmpPath(&tmp, "conduit.log", &log_path_buffer);
    var crash_buffer: [path_capacity]u8 = undefined;
    const crash_path = try crashPathFor(&crash_buffer, log_path);
    try sink.install(std.testing.io, .{ .level = .debug, .file = log_path });
    defer sink.deinit();

    sensitiveLog("the last thing that happened", .{});
    // `emit`, not `log.info`: the sink is what is under test, and going
    // through the `std.log` scope here would prove the scope rather than the
    // sink.
    emit(.info, .app, "a line the reader will want", .{});
    if (sink.file) |*file| file.interface.flush() catch {};
    sink.deinit();

    writeCrashReport(std.testing.io, .{
        .message = "index out of bounds: index 7, len 3",
        .log_path = log_path,
        .crash_path = crash_path,
    });

    var report: [64 * 1024]u8 = undefined;
    const contents = try readInTmp(&tmp, "conduit.crash.txt", &report);
    try std.testing.expect(std.mem.indexOf(u8, contents, "conduit crash report") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "index out of bounds: index 7, len 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "--- stack trace ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "--- log tail ---") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "a line the reader will want") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "log file: ") != null);
}

test "a crash report without a log says so rather than inventing one" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [path_capacity]u8 = undefined;
    const crash_path = try tmpPath(&tmp, "early.crash.txt", &path_buffer);
    writeCrashReport(std.testing.io, .{ .message = "boom", .crash_path = crash_path });

    var report: [16 * 1024]u8 = undefined;
    const contents = try readInTmp(&tmp, "early.crash.txt", &report);
    try std.testing.expect(std.mem.indexOf(u8, contents, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "log file: (none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "no log tail available") != null);
}

test "readLogTail returns whole lines, not a fragment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = std.testing.io;
    var path_buffer: [path_capacity]u8 = undefined;
    const path = try tmpPath(&tmp, "run-1.log", &path_buffer);
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = "first\nsecond\nthird\n" });

    var buffer: [16]u8 = undefined;
    const tail = readLogTail(io, path, &buffer) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!std.mem.startsWith(u8, tail, "cond"));
    try std.testing.expect(std.mem.endsWith(u8, tail, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, tail, "third") != null);
}

test "the app preserves a committed payload larger than the key buffer" {
    const testing = std.testing;
    var composition: inputmod.Composition = .{};

    const preedit = routeInputMethodEvent(
        &composition,
        .{ .text_editing = platform.TextEditing.editing("konnichiha", 6, 4) },
    );
    try testing.expect(preedit == .preedit);
    try testing.expectEqualStrings("konnichiha", composition.preedit());
    try testing.expectEqual(@as(u32, 6), composition.selection().start);
    try testing.expectEqual(@as(u32, 4), composition.selection().length);

    const candidates = platform.Candidates.candidates(&.{ "こんにちは", "今日は" }, 1, false);
    const offered = routeInputMethodEvent(&composition, .{ .candidates = candidates });
    try testing.expect(offered == .candidates);
    try testing.expectEqualStrings("今日は", composition.offered().current().?);

    const long_commit: [term.max_encoded_key_bytes + 17]u8 = @splat('x');
    const result = routeInputMethodEvent(&composition, .{ .text_input = long_commit[0..] });
    const committed = switch (result) {
        .committed => |text| text,
        else => return error.TestUnexpectedResult,
    };
    var pending: []const u8 = "";
    queueCommittedText(&pending, committed);
    try testing.expect(pending.len > term.max_encoded_key_bytes);
    try testing.expectEqualSlices(u8, long_commit[0..], pending);
    const taken = takeCommittedText(&pending);
    try testing.expectEqualSlices(u8, long_commit[0..], taken);
    try testing.expectEqualStrings("", pending);
    try testing.expect(!composition.isComposing());
    try testing.expectEqual(@as(usize, 0), composition.offered().len());
}

test "the app marks keys as composing only while its preedit is live" {
    const testing = std.testing;
    var composition: inputmod.Composition = .{};
    var scratch: inputmod.TextScratch = .{};
    const key: platform.KeyEvent = .{
        .action = .press,
        .codepoint = 'k',
        .unshifted_codepoint = 'k',
    };

    const ordinary = translateAppKey(&composition, &scratch, key);
    try testing.expect(!ordinary.encoded.composing);

    _ = routeInputMethodEvent(
        &composition,
        .{ .text_editing = platform.TextEditing.editing("k", 1, 0) },
    );
    const composing = translateAppKey(&composition, &scratch, key);
    try testing.expect(composing.encoded.composing);

    _ = routeInputMethodEvent(&composition, .{ .text_input = "か" });
    const after_commit = translateAppKey(&composition, &scratch, key);
    try testing.expect(!after_commit.encoded.composing);
}

test "text input placement converts device pixels to logical pixels" {
    try std.testing.expectEqual(@as(u32, 8), logicalPixels(16, platform.Scale.fromPlatform(2.0)));
    try std.testing.expectEqual(@as(u32, 17), logicalPixels(17, platform.Scale.fromPlatform(1.0)));
}

test "preedit caret width follows terminal graphemes and safe UTF-8 boundaries" {
    try std.testing.expectEqual(@as(?u32, 1), preeditCellWidth("a"));
    try std.testing.expectEqual(@as(?u32, 2), preeditCellWidth("日"));
    try std.testing.expectEqual(@as(?u32, 1), preeditCellWidth("e\u{301}"));
    try std.testing.expect(preeditCellWidth("\xff") == null);
    try std.testing.expect(utf8Boundary("日本", 3));
    try std.testing.expect(!utf8Boundary("日本", 1));
}

test "the window defaults are a visible window that runs until it is closed" {
    const env = test_env{ .vars = &.{} };
    const options = try parseArgs(&.{"conduit"}, env.source());

    try std.testing.expectEqual(default_width, options.run.width);
    try std.testing.expectEqual(default_height, options.run.height);
    try std.testing.expect(options.run.scale == null);
    try std.testing.expect(!options.run.hidden);
    try std.testing.expect(!options.run.force_redraw);
    try std.testing.expect(!options.run.self_test);
    // No budget: the run leaves when the window closes, which is what a person
    // at a terminal expects and what `--run-ms` exists to override.
    try std.testing.expect(options.run.run_ms == null);
}

test "the window and run flags are read in either spelling" {
    const env = test_env{ .vars = &.{} };
    const spaced = try parseArgs(&.{
        "conduit",  "--width",        "640",
        "--height", "480",            "--scale",
        "1.5",      "--run-ms",       "250",
        "--hidden", "--force-redraw", "--self-test",
    }, env.source());

    try std.testing.expectEqual(@as(u32, 640), spaced.run.width);
    try std.testing.expectEqual(@as(u32, 480), spaced.run.height);
    try std.testing.expectEqual(@as(f32, 1.5), spaced.run.scale.?);
    try std.testing.expectEqual(@as(u32, 250), spaced.run.run_ms.?);
    try std.testing.expect(spaced.run.hidden);
    try std.testing.expect(spaced.run.force_redraw);
    try std.testing.expect(spaced.run.self_test);

    const equals = try parseArgs(&.{
        "conduit",
        "--width=640",
        "--height=480",
        "--scale=1.5",
        "--run-ms=250",
        "--hidden",
        "--force-redraw",
        "--self-test",
    }, env.source());
    try std.testing.expectEqual(spaced.run, equals.run);

    // The diagnostics flags and the window flags live in one pass, so asking
    // for both together has to work.
    const both = try parseArgs(&.{ "conduit", "--log-level=warn", "--hidden" }, env.source());
    try std.testing.expectEqual(Level.warn, both.level);
    try std.testing.expect(both.run.hidden);
}

test "the automation server requires an explicit endpoint flag" {
    const env = test_env{ .vars = &.{} };
    const disabled = try parseArgs(&.{"conduit"}, env.source());
    try std.testing.expect(disabled.run.test_driver_endpoint == null);
    try std.testing.expect(!testdriver.isEnabled(disabled.run.test_driver_endpoint != null));

    const explicit = try parseArgs(&.{ "conduit", "--test-driver=.zig-cache/conduit/test.sock" }, env.source());
    try std.testing.expectEqualStrings(".zig-cache/conduit/test.sock", explicit.run.test_driver_endpoint.?);
    try std.testing.expect(testdriver.isEnabled(explicit.run.test_driver_endpoint != null));

    const artifacts = try parseArgs(&.{ "conduit", "--test-artifact-dir=.zig-cache/conduit/run" }, env.source());
    try std.testing.expectEqualStrings(".zig-cache/conduit/run", artifacts.run.test_artifact_dir.?);

    const check = try parseArgs(&.{ "conduit", "--driver-test" }, env.source());
    try std.testing.expect(check.run.driver_test);
    const resolved = optionsForRun(check);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(resolved.run.no_child);
    try std.testing.expectEqual(@as(f32, 1.0), resolved.run.scale.?);
}

test "the UI check owns a hidden fixed viewport and bundled font" {
    const resolved = optionsForRun(.{ .run = .{
        .width = 123,
        .height = 456,
        .hidden = false,
        .force_redraw = true,
        .run_ms = 1,
        .command = "echo not-run",
        .font_family = "system font",
        .ui_test = true,
    } });

    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.force_redraw);
    try std.testing.expect(resolved.run.run_ms == null);
    try std.testing.expect(resolved.run.command == null);
    try std.testing.expectEqualStrings("", resolved.run.font_family);
    try std.testing.expect(resolved.run.no_child);
    try std.testing.expect(resolved.run.ui_test);
}

test "the IME check owns a hidden fixed viewport and real child" {
    const resolved = optionsForRun(.{ .run = .{
        .width = 123,
        .height = 456,
        .hidden = false,
        .force_redraw = true,
        .run_ms = 1,
        .command = "echo not-run",
        .font_family = "system font",
        .no_child = true,
        .ime_test = true,
    } });

    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(!resolved.run.force_redraw);
    try std.testing.expect(resolved.run.run_ms == null);
    try std.testing.expect(resolved.run.command == null);
    try std.testing.expectEqualStrings("", resolved.run.font_family);
    try std.testing.expect(!resolved.run.no_child);
    try std.testing.expect(resolved.run.ime_test);
}

test "the sidebar check owns a hidden fixed viewport and childless production UI" {
    const env = test_env{ .vars = &.{} };
    const parsed = try parseArgs(&.{ "conduit", "--sidebar-test" }, env.source());
    const resolved = optionsForRun(parsed);

    try std.testing.expect(parsed.run.sidebar_test);
    try std.testing.expect(std.mem.indexOf(u8, usage, "--sidebar-test") != null);
    try std.testing.expectEqual(ui_test_width, resolved.run.width);
    try std.testing.expectEqual(ui_test_height, resolved.run.height);
    try std.testing.expect(resolved.run.hidden);
    try std.testing.expect(resolved.run.no_child);
    try std.testing.expect(!wantsChild(resolved));
    try std.testing.expect(sidebarEnabled(resolved));
    try std.testing.expect(sidebarStartsVisible(resolved));
}

test "a window of no pixels and a nonsense size are config errors" {
    const env = test_env{ .vars = &.{} };
    try std.testing.expectError(error.InvalidSize, parseArgs(&.{ "conduit", "--width=0" }, env.source()));
    try std.testing.expectError(error.InvalidSize, parseArgs(&.{ "conduit", "--height=0" }, env.source()));
    try std.testing.expectError(error.InvalidSize, parseArgs(&.{ "conduit", "--width=wide" }, env.source()));
    try std.testing.expectError(error.InvalidSize, parseArgs(&.{ "conduit", "--run-ms=soon" }, env.source()));
    try std.testing.expectError(error.InvalidScale, parseArgs(&.{ "conduit", "--scale=0" }, env.source()));
    try std.testing.expectError(error.InvalidScale, parseArgs(&.{ "conduit", "--scale=nan" }, env.source()));
    try std.testing.expectError(error.InvalidScale, parseArgs(&.{ "conduit", "--scale=huge" }, env.source()));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--width" }, env.source()));
    try std.testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--scale" }, env.source()));

    // A run budget of zero is a real answer — leave as soon as there is a frame —
    // while a window of zero pixels is not.
    const zero_budget = try parseArgs(&.{ "conduit", "--run-ms=0" }, env.source());
    try std.testing.expectEqual(@as(u32, 0), zero_budget.run.run_ms.?);
}

test "the loop draws the first frame and then stops drawing until something changes" {
    var scheduler = Scheduler.init(false);
    // Nothing has ever been drawn, so there is something owed.
    try std.testing.expect(scheduler.shouldDraw());

    scheduler.drawn();
    try std.testing.expect(!scheduler.shouldDraw());
    try std.testing.expectEqual(@as(u64, 1), scheduler.frames);

    // An idle iteration must not draw, or the loop is a busy loop wearing a
    // window.
    try std.testing.expect(!scheduler.shouldDraw());
    try std.testing.expectEqual(@as(u64, 1), scheduler.frames);

    // A resize, a scale change and an expose all invalidate, and one invalidation
    // is one frame: three of them before the loop runs are still one frame.
    scheduler.invalidate();
    scheduler.invalidate();
    scheduler.invalidate();
    try std.testing.expect(scheduler.shouldDraw());
    scheduler.drawn();
    try std.testing.expectEqual(@as(u64, 2), scheduler.frames);
    try std.testing.expect(!scheduler.shouldDraw());
}

test "forcing a redraw draws every iteration, which is what makes it a measurement" {
    var scheduler = Scheduler.init(true);
    scheduler.drawn();
    // On demand it would stop here; forced, it never does.
    try std.testing.expect(scheduler.shouldDraw());
    scheduler.drawn();
    try std.testing.expect(scheduler.shouldDraw());
    try std.testing.expectEqual(@as(u64, 2), scheduler.frames);
}

test "a capture is read top-down and its pixels are counted exactly" {
    const size = render.Size{ .width = 2, .height = 2 };
    const want = render.Rgba{ .r = 0x16, .g = 0x1a, .b = 0x22 };
    // Top-down, as `render.read` returns it: the first pixel is the top-left one.
    const pixels = [_]u8{
        0x16, 0x1a, 0x22, 255, 0x16, 0x1a, 0x22, 255,
        0x16, 0x1a, 0x22, 255, 0x16, 0x1a, 0x22, 255,
    };

    try std.testing.expectEqual(want, pixelAt(&pixels, size, 0, 0));
    try std.testing.expectEqual(want, pixelAt(&pixels, size, 1, 0));
    try std.testing.expectEqual(want, pixelAt(&pixels, size, 0, 1));
    try std.testing.expectEqual(want, pixelAt(&pixels, size, 1, 1));
    try std.testing.expectEqual(@as(usize, 4), countPixels(&pixels, want));

    // One pixel off by one in any channel is not the colour, and the count says
    // so: "the surface is the background" has to mean every pixel.
    const nearly = [_]u8{
        0x16, 0x1a, 0x22, 255, 0x16, 0x1a, 0x22, 255,
        0x16, 0x1a, 0x22, 255, 0x16, 0x1a, 0x23, 255,
    };
    try std.testing.expectEqual(@as(usize, 3), countPixels(&nearly, want));
    try std.testing.expectEqual(render.Rgba{ .r = 0x16, .g = 0x1a, .b = 0x23 }, pixelAt(&nearly, size, 1, 1));
}

test "the surface size is the window's physical size and nothing else" {
    const state = platform.State.init(
        .{ .width = 640, .height = 480 },
        platform.Scale.fromPlatform(2.0),
    );
    try std.testing.expectEqual(render.Size{ .width = 1280, .height = 960 }, surfaceSize(state));

    // A scale change moves the surface and leaves the logical size alone.
    const moved = state.rescaled(platform.Scale.fromPlatform(1.0));
    try std.testing.expectEqual(state.logical, moved.logical);
    try std.testing.expectEqual(render.Size{ .width = 640, .height = 480 }, surfaceSize(moved));
}

test "a run budget is a deadline and no budget blocks indefinitely" {
    const io = std.testing.io;
    const budget = runDeadline(io, 500);
    try std.testing.expect(budget != null);
    // The deadline is roughly half a second away: a budget of 0 would already be
    // in the past, and a budget in the past would not be a budget.
    const left = budget.? - Io.Clock.real.now(io).nanoseconds;
    try std.testing.expect(left > 0 and left <= 500 * std.time.ns_per_ms);

    try std.testing.expect(runDeadline(io, null) == null);
}

test "the loop's wait is a blocking wait without a deadline and the remainder with one" {
    const io = std.testing.io;
    // -1 is SDL's "block until an event arrives", and it is the only thing that
    // makes an idle window cost nothing.
    try std.testing.expectEqual(@as(i32, -1), eventWaitBudget(io, null, false));

    // A deadline in the past means "look now", never a negative wait.
    try std.testing.expectEqual(@as(i32, 0), eventWaitBudget(io, 0, false));

    const remaining = eventWaitBudget(io, Io.Clock.real.now(io).nanoseconds + 100 * std.time.ns_per_ms, false);
    try std.testing.expect(remaining > 0 and remaining <= 100);

    // Force mode polls, whatever the deadline says, because a loop that draws
    // every frame is exactly a loop that does not sleep.
    try std.testing.expectEqual(@as(i32, 0), eventWaitBudget(io, null, true));
    try std.testing.expectEqual(@as(i32, 0), eventWaitBudget(io, Io.Clock.real.now(io).nanoseconds + 1000 * std.time.ns_per_ms, true));
}

test "a palette colour becomes a surface colour, all four channels" {
    const testing = std.testing;

    try testing.expectEqual(
        render.Rgba{ .r = 0x7f, .g = 0x80, .b = 0x81, .a = 0x82 },
        surfaceColor(.{ .r = 0x7f, .g = 0x80, .b = 0x81, .a = 0x82 }),
    );
    // Alpha defaults to opaque, and the conversion does not invent a different
    // one: a role that is translucent stays translucent.
    try testing.expectEqual(@as(u8, 255), surfaceColor(.{ .r = 1, .g = 2, .b = 3 }).a);
}

test "the grid's colours are the palette's, in the slots a program names" {
    const testing = std.testing;

    const colors = gridColors(default_palette);

    // Slot `n` is the colour an SGR parameter of `30 + n` asks for, which is
    // `theme.Role`'s slot order and nothing else's.
    for (std.enums.values(theme.Role), 0..) |role, slot| {
        if (!role.isAnsi()) continue;
        try testing.expectEqual(surfaceColor(default_palette.get(role)), colors.ansi[slot]);
    }
    try testing.expectEqual(surfaceColor(default_palette.get(.red)), colors.ansi[1]);
    try testing.expectEqual(surfaceColor(default_palette.get(.bright_red)), colors.ansi[9]);

    // The named roles are not ANSI slots, so they are not in the array.
    try testing.expectEqual(surfaceColor(default_palette.get(.foreground)), colors.foreground);
    try testing.expectEqual(surfaceColor(default_palette.get(.background)), colors.background);
    try testing.expectEqual(surfaceColor(default_palette.get(.foreground)), colors.cursor);

    // And the one place the old constant and the palette both say what a
    // surface is cleared to have to agree.
    try testing.expectEqual(background, colors.background);
}

test "the terminal flags are parsed, and a value flag refuses a missing value" {
    const testing = std.testing;
    const empty = test_env{ .vars = &.{} };
    const env = empty.source();

    const options = try parseArgs(&.{
        "conduit",
        "--command=echo hi",
        "--screenshot=/tmp/out.png",
        "--font=DejaVu Sans Mono",
        "--grid-test",
        "--scroll-test",
        "--mouse-test",
        "--ui-test",
        "--ime-test",
        "--sidebar-test",
        "--tabs-test",
        "--panes-test",
        "--scratchpad-test",
        "--palette-test",
        "--workspaces-test",
        "--links-test",
        "--search-test",
        "--menu-test",
        "--no-child",
    }, env);
    try testing.expectEqualStrings("echo hi", options.run.command.?);
    try testing.expectEqualStrings("/tmp/out.png", options.run.screenshot.?);
    try testing.expectEqualStrings("DejaVu Sans Mono", options.run.font_family);
    try testing.expect(options.run.grid_test);
    try testing.expect(options.run.scroll_test);
    try testing.expect(options.run.mouse_test);
    try testing.expect(options.run.ui_test);
    try testing.expect(options.run.ime_test);
    try testing.expect(options.run.sidebar_test);
    try testing.expect(options.run.tabs_test);
    try testing.expect(options.run.panes_test);
    try testing.expect(options.run.scratchpad_test);
    try testing.expect(options.run.palette_test);
    try testing.expect(options.run.workspaces_test);
    try testing.expect(options.run.links_test);
    try testing.expect(options.run.search_test);
    try testing.expect(options.run.menu_test);
    try testing.expect(options.run.no_child);

    // The defaults are the ones a plain run uses: an interactive shell, no
    // screenshot and the bundled face.
    const plain = try parseArgs(&.{"conduit"}, env);
    try testing.expect(plain.run.command == null);
    try testing.expect(plain.run.screenshot == null);
    try testing.expectEqualStrings("", plain.run.font_family);
    try testing.expect(!plain.run.grid_test);
    try testing.expect(!plain.run.scroll_test);
    try testing.expect(!plain.run.mouse_test);
    try testing.expect(!plain.run.ui_test);
    try testing.expect(!plain.run.ime_test);
    try testing.expect(!plain.run.sidebar_test);
    try testing.expect(!plain.run.tabs_test);
    try testing.expect(!plain.run.panes_test);
    try testing.expect(!plain.run.scratchpad_test);
    try testing.expect(!plain.run.palette_test);
    try testing.expect(!plain.run.workspaces_test);
    try testing.expect(!plain.run.links_test);
    try testing.expect(!plain.run.search_test);
    try testing.expect(!plain.run.menu_test);
    try testing.expect(!plain.run.no_child);
    try testing.expect(wantsChild(plain));

    // A flag value may also be the next argument, and a missing one is an error
    // rather than an empty command.
    const split = try parseArgs(&.{ "conduit", "--command", "ls" }, env);
    try testing.expectEqualStrings("ls", split.run.command.?);
    try testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--command" }, env));
    try testing.expectError(error.MissingValue, parseArgs(&.{ "conduit", "--screenshot" }, env));
    try testing.expectError(error.UnknownFlag, parseArgs(&.{ "conduit", "--nonsense" }, env));
}

test "a run only wants a child when nothing asked for a still grid" {
    const testing = std.testing;

    try testing.expect(wantsChild(.{}));

    // The checks measure a grid, and a program's output arriving underneath a
    // measurement would make the measurement about the program.
    try testing.expect(!wantsChild(.{ .run = .{ .self_test = true } }));
    try testing.expect(!wantsChild(.{ .run = .{ .grid_test = true } }));
    try testing.expect(!wantsChild(.{ .run = .{ .scroll_test = true } }));
    try testing.expect(!wantsChild(.{ .run = .{ .mouse_test = true } }));
    try testing.expect(!wantsChild(.{ .run = .{ .ui_test = true } }));
    try testing.expect(wantsChild(.{ .run = .{ .ime_test = true } }));
    try testing.expect(wantsChild(.{ .run = .{ .tabs_test = true } }));
    try testing.expect(wantsChild(.{ .run = .{ .panes_test = true } }));
    try testing.expect(!wantsChild(optionsForRun(.{ .run = .{ .scratchpad_test = true } })));
    try testing.expect(wantsChild(optionsForRun(.{ .run = .{ .palette_test = true } })));
    try testing.expect(wantsChild(optionsForRun(.{ .run = .{ .workspaces_test = true } })));
    try testing.expect(wantsChild(optionsForRun(.{ .run = .{ .links_test = true } })));
    try testing.expect(wantsChild(optionsForRun(.{ .run = .{ .search_test = true } })));
    try testing.expect(wantsChild(optionsForRun(.{ .run = .{ .menu_test = true } })));
    try testing.expect(!wantsChild(.{ .run = .{ .no_child = true } }));
}

test "two captures are compared pixel by pixel, not byte by byte" {
    const testing = std.testing;

    const red = [_]u8{ 255, 0, 0, 255 };
    const blue = [_]u8{ 0, 0, 255, 255 };

    var before: [8]u8 = undefined;
    @memcpy(before[0..4], &red);
    @memcpy(before[4..8], &red);

    // One pixel changed is one difference, whether it is the first or the last.
    var after: [8]u8 = before;
    @memcpy(after[0..4], &blue);
    try testing.expectEqual(@as(usize, 1), countDifferingPixels(&before, &after));

    @memcpy(after[0..4], &red);
    @memcpy(after[4..8], &blue);
    try testing.expectEqual(@as(usize, 1), countDifferingPixels(&before, &after));

    try testing.expectEqual(@as(usize, 0), countDifferingPixels(&before, &before));

    // A capture truncated by the surface growing is compared over what both
    // hold, rather than reading past the end of either.
    // Only whole pixels are compared, so the difference the truncated pair
    // reports has to be in the one pixel both of them still hold.
    @memcpy(after[0..4], &blue);
    try testing.expectEqual(@as(usize, 1), countDifferingPixels(before[0..8], after[0..7]));

    // An empty capture has no pixels to differ in.
    try testing.expectEqual(@as(usize, 0), countDifferingPixels(before[0..0], after[0..0]));
}

test "the grid the surface can hold is whole cells, and never empty" {
    const testing = std.testing;

    // 8x17 cells in a 100x60 surface: twelve columns fit, three rows, and the
    // remaining pixels are not part of the terminal.
    const size = render.Size{ .width = 100, .height = 60 };
    const grid = try gridSizeFor(font.CellSize.init(8, 17), size);
    try testing.expectEqual(@as(u16, 12), grid.cols);
    try testing.expectEqual(@as(u16, 3), grid.rows);

    // A surface smaller than one cell still gets a terminal: a grid of no cells
    // is not a terminal, and the renderer divides by the cell size.
    const tiny = try gridSizeFor(font.CellSize.init(8, 17), .{ .width = 1, .height = 1 });
    try testing.expectEqual(@as(u16, 1), tiny.cols);
    try testing.expectEqual(@as(u16, 1), tiny.rows);
}

test "a capture diff counts the pixels that moved, not the box around them" {
    const testing = std.testing;

    const size = render.Size{ .width = 4, .height = 2 };
    var before = [_]u8{0} ** (size.width * size.height * 4);
    var after = before;

    // Two pixels, at opposite corners. The box between them is eight times
    // their count, so a check that reported the box area as "pixels differ"
    // would overstate this by 8x — which is what `--grid-test` used to print.
    after[(0 * size.width + 0) * 4 + 0] = 255;
    after[(1 * size.width + 3) * 4 + 3] = 255;

    const diff = diffPixels(&before, &after, size) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), diff.count);
    try testing.expectEqual(InkBox{ .x = 0, .y = 0, .width = 4, .height = 2 }, diff.box);
    try testing.expect(diff.box.width * diff.box.height > diff.count);

    // Identical captures are not a difference at all, which is the case a frame
    // with nothing to redraw has to be able to say.
    try testing.expect(diffPixels(&before, &before, size) == null);

    // Two captures of different lengths are refused rather than compared half
    // way: a partial comparison would report a difference nobody can place.
    try testing.expect(diffPixels(&before, before[0 .. before.len - 4], size) == null);
}

test "a difference is inside a rectangle only when all of it is" {
    const testing = std.testing;

    const diff = Difference{
        .count = 7,
        .box = .{ .x = 4, .y = 20, .width = 8, .height = 20 },
    };
    // Exactly the cell the difference is in.
    try testing.expect(diff.inside(inkBounds(.{ .x = 4, .y = 20, .width = 8, .height = 20 })));
    // A rectangle that wholly contains it.
    try testing.expect(diff.inside(inkBounds(.{ .x = 0, .y = 0, .width = 96, .height = 100 })));
    // Starting one pixel late does not contain it, however much else it covers.
    try testing.expect(!diff.inside(inkBounds(.{ .x = 5, .y = 20, .width = 8, .height = 20 })));
    // And ending one pixel early does not either.
    try testing.expect(!diff.inside(inkBounds(.{ .x = 4, .y = 20, .width = 7, .height = 20 })));
}

test "a cell rectangle is whole pixels, not a float" {
    const testing = std.testing;

    const bounds = inkBounds(render.cellRect(1, 2, font.CellSize.init(8, 20)));
    try testing.expectEqual(InkBox{ .x = 8, .y = 40, .width = 8, .height = 20 }, bounds);
}

test "damage is the rows it names, and nothing else" {
    const testing = std.testing;

    try testing.expect(damageIs(.none, &.{}));
    try testing.expect(!damageIs(.none, &.{1}));
    try testing.expect(damageIs(.{ .rows = &.{1} }, &.{1}));
    try testing.expect(damageIs(.{ .rows = &.{ 1, 4 } }, &.{ 1, 4 }));
    // Order and count are part of what the terminal said, so both are compared.
    try testing.expect(!damageIs(.{ .rows = &.{ 4, 1 } }, &.{ 1, 4 }));
    try testing.expect(!damageIs(.{ .rows = &.{1} }, &.{ 1, 1 }));
    // A full repaint is never "these rows", and rows are never "a full repaint".
    try testing.expect(!damageIs(.full, &.{0}));
    try testing.expect(!damageIs(.{ .rows = &.{0} }, &.{}));
}

test "a shell is recognised by its file name, and an unknown one gets nothing" {
    try std.testing.expectEqual(ShellKind.bash, ShellKind.detect("/usr/bin/bash").?);
    try std.testing.expectEqual(ShellKind.zsh, ShellKind.detect("zsh").?);
    try std.testing.expectEqual(ShellKind.fish, ShellKind.detect("/opt/fish/bin/fish").?);
    // Conduit never guesses: a name it has no script for is no integration.
    for ([_][]const u8{ "/bin/sh", "/usr/bin/dash", "tcsh", "nu", "/bin/bash5", "bashful", "" }) |program| {
        try std.testing.expect(ShellKind.detect(program) == null);
    }
}

/// The environment a shell-integration test spawns with: no user startup files
/// are found because `HOME` is the test's own empty directory.
fn shellTestSpec(gpa: Allocator, home_relative: []const u8, shell: []const u8, root: []const u8, disabled: bool) !ChildSpec {
    // Absolute, because the shell starts in `/` and a relative HOME would name
    // a directory that is not there from where it stands.
    const home = try Dir.cwd().realPathFileAlloc(std.testing.io, home_relative, gpa);
    defer gpa.free(home);
    const env = test_env{ .vars = &.{
        .{ "SHELL", shell },
        .{ "HOME", home },
        .{ "PATH", "/usr/bin:/bin" },
        .{ "LANG", "C.UTF-8" },
    } };
    var options: Options = .{};
    options.run.no_shell_integration = disabled;
    return ChildSpec.buildIn(gpa, std.testing.io, env.source(), options, root);
}

/// Run `cd /tmp && false` in a real shell started by Conduit's own `ChildSpec`,
/// over a real PTY, into Conduit's own terminal; report what the terminal
/// tracked. Every wait is a condition with a deadline: the shell's own
/// `__done__` marker, then the child's end.
const ShellRun = struct {
    cwd: ?[]u8,
    prompt_starts: usize,
    command_ends: usize,
    /// The status the first finished command reported: `cd /tmp && false`.
    first_exit: ?i32,
    /// How many prompt rows the terminal recorded once the shell had gone.
    prompt_rows: usize,
};

fn runShellInConduit(gpa: Allocator, spec: ChildSpec) !ShellRun {
    var terminal: term.Terminal = undefined;
    try terminal.init(std.testing.io, gpa, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(gpa);

    var execution = try workspace.ExecutionContext.local(gpa);
    defer execution.deinit();
    const child = try execution.borrow().spawn(.{
        .argv = spec.argv,
        .env = spec.env,
        .cwd = "/",
        .size = .init(24, 80),
    });
    defer child.destroy();

    var run: ShellRun = .{ .cwd = null, .prompt_starts = 0, .command_ends = 0, .first_exit = null, .prompt_rows = 0 };
    errdefer if (run.cwd) |dir| gpa.free(dir);
    var buffer: [4096]u8 = undefined;
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);
    var typed = false;
    var exited = false;

    // Read until the child has gone and its last bytes have been taken. A
    // stop on "the command finished" would race the shell's next prompt,
    // whose working-directory report arrives after the command's output.
    const deadline = Io.Clock.real.now(std.testing.io).nanoseconds + 10 * std.time.ns_per_s;
    while (Io.Clock.real.now(std.testing.io).nanoseconds < deadline) {
        const got = child.takeBytes(&buffer);
        if (got != 0) {
            terminal.feed(buffer[0..got]);
            try seen.appendSlice(gpa, buffer[0..got]);
            for (terminal.takeEvents()) |event| switch (event) {
                .working_directory => |dir| {
                    if (run.cwd) |old| gpa.free(old);
                    run.cwd = try gpa.dupe(u8, dir);
                },
                .prompt => |mark| switch (mark.kind) {
                    .prompt_start => run.prompt_starts += 1,
                    .command_end => {
                        run.command_ends += 1;
                        if (run.command_ends == 1) run.first_exit = mark.exit_code;
                    },
                    else => {},
                },
                else => {},
            };
            continue;
        }
        // The first prompt is drawn once the shell has read its startup
        // files; only then is the command line typed.
        if (!typed and (std.mem.indexOf(u8, seen.items, "$ ") != null or std.mem.indexOf(u8, seen.items, "% ") != null)) {
            // Two commands, so the status of the first is `false`'s own and
            // not the marker's.
            _ = try child.write("cd /tmp && false\necho __done__\n");
            typed = true;
        }
        // Typing `exit` now is safe because the loop keeps reading until the
        // child has gone: the prompt after the command, and its
        // working-directory report, are drawn before the shell reads the line.
        if (typed and !exited and std.mem.count(u8, seen.items, "__done__") >= 2) {
            _ = try child.write("exit\n");
            exited = true;
        }
        if (exited and child.state() != .running) break;
        _ = child.waitReadable(50);
    }
    var rows: [16]u32 = undefined;
    run.prompt_rows = terminal.promptRows(&rows);
    return run;
}

fn requireShell(path: []const u8) !void {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch {
        std.debug.print("SKIP: {s} is not installed, so this shell's integration is unverified here\n", .{path});
        return error.SkipZigTest;
    };
}

test "a real bash started by Conduit reports its directory and marks its prompts" {
    try requireShell("/usr/bin/bash");
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [path_capacity]u8 = undefined;
    const home = try tmpPath(&tmp, "", &home_buffer);
    var root_buffer: [path_capacity]u8 = undefined;
    const root = try tmpPath(&tmp, "integration", &root_buffer);

    var spec = try shellTestSpec(gpa, home, "/usr/bin/bash", root, false);
    defer spec.deinit();
    // What Conduit hands bash: POSIX mode, the script as ENV, and the flag the
    // script replays the user's startup files on.
    try std.testing.expectEqualStrings("--posix", spec.argv[1]);
    try std.testing.expect(hasEntry(spec.env, "CONDUIT_BASH_INJECT=1"));
    try std.testing.expect(hasEntry(spec.env, "TERM_PROGRAM=conduit"));

    const run = try runShellInConduit(gpa, spec);
    defer if (run.cwd) |dir| gpa.free(dir);
    try std.testing.expectEqualStrings("/tmp", run.cwd orelse return error.NoWorkingDirectory);
    try std.testing.expect(run.prompt_starts >= 2);
    try std.testing.expect(run.command_ends >= 2);
    // `false` was the command; its status reaches the prompt mark.
    try std.testing.expectEqual(@as(?i32, 1), run.first_exit);
    // Each prompt the shell marked is a row a jump-to-prompt can reach.
    try std.testing.expect(run.prompt_rows >= 2);
}

test "a real zsh started by Conduit reports its directory and marks its prompts" {
    try requireShell("/usr/bin/zsh");
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [path_capacity]u8 = undefined;
    const home = try tmpPath(&tmp, "", &home_buffer);
    var root_buffer: [path_capacity]u8 = undefined;
    const root = try tmpPath(&tmp, "integration", &root_buffer);

    var spec = try shellTestSpec(gpa, home, "/usr/bin/zsh", root, false);
    defer spec.deinit();
    // zsh is not given --posix; it is pointed at the integration's ZDOTDIR,
    // with the user's own (absent) value carried along to be restored.
    try std.testing.expectEqual(@as(usize, 1), spec.argv.len);
    try std.testing.expect(hasEntry(spec.env, "CONDUIT_ZSH_ZDOTDIR="));

    const run = try runShellInConduit(gpa, spec);
    defer if (run.cwd) |dir| gpa.free(dir);
    try std.testing.expectEqualStrings("/tmp", run.cwd orelse return error.NoWorkingDirectory);
    try std.testing.expect(run.prompt_starts >= 2);
    try std.testing.expect(run.command_ends >= 2);
    try std.testing.expectEqual(@as(?i32, 1), run.first_exit);
    // Each prompt the shell marked is a row a jump-to-prompt can reach.
    try std.testing.expect(run.prompt_rows >= 2);
}

test "--no-shell-integration starts the shell untouched, and it reports nothing" {
    try requireShell("/usr/bin/bash");
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [path_capacity]u8 = undefined;
    const home = try tmpPath(&tmp, "", &home_buffer);
    var root_buffer: [path_capacity]u8 = undefined;
    const root = try tmpPath(&tmp, "integration", &root_buffer);

    var spec = try shellTestSpec(gpa, home, "/usr/bin/bash", root, true);
    defer spec.deinit();
    // No --posix, no ENV, no inject flag: bash starts as it would without Conduit.
    try std.testing.expectEqual(@as(usize, 1), spec.argv.len);
    for (spec.env) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry, "ENV="));
        try std.testing.expect(!std.mem.startsWith(u8, entry, "CONDUIT_BASH_INJECT="));
        try std.testing.expect(!std.mem.startsWith(u8, entry, "ZDOTDIR="));
    }

    const run = try runShellInConduit(gpa, spec);
    defer if (run.cwd) |dir| gpa.free(dir);
    try std.testing.expect(run.cwd == null);
    try std.testing.expectEqual(@as(usize, 0), run.prompt_starts);
    try std.testing.expectEqual(@as(usize, 0), run.command_ends);
    try std.testing.expectEqual(@as(usize, 0), run.prompt_rows);
}

test "the flag is parsed, and a script run never gets shell integration" {
    const env = test_env{ .vars = &.{} };
    const options = try parseArgs(&.{ "conduit", "--no-shell-integration" }, env.source());
    try std.testing.expect(options.run.no_shell_integration);
    try std.testing.expect(!(try parseArgs(&.{"conduit"}, env.source())).run.no_shell_integration);

    // `--command` runs a script under /bin/sh, which is not an interactive
    // shell, so none of the integration's variables are set.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [path_capacity]u8 = undefined;
    const root = try tmpPath(&tmp, "integration", &root_buffer);
    var options_cmd: Options = .{};
    options_cmd.run.command = "echo hi";
    const shell_env = test_env{ .vars = &.{.{ "SHELL", "/usr/bin/bash" }} };
    var spec = try ChildSpec.buildIn(std.testing.allocator, std.testing.io, shell_env.source(), options_cmd, root);
    defer spec.deinit();
    try std.testing.expectEqualStrings("/bin/sh", spec.argv[0]);
    for (spec.env) |entry| try std.testing.expect(!std.mem.startsWith(u8, entry, "CONDUIT_BASH_INJECT="));
}

fn hasEntry(entries: []const []const u8, wanted: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry, wanted)) return true;
    return false;
}

test "logical pointer coordinates become finite clamped device pixels" {
    const doubled = platform.Scale.fromPlatform(2.0);
    try std.testing.expectEqual(ui.Point{ .x = 7, .y = -3 }, devicePointerPoint(3.75, -1.25, doubled));
    try std.testing.expectEqual(@as(i32, 0), devicePointerCoordinate(std.math.nan(f32), doubled));
    try std.testing.expectEqual(@as(i32, 0), devicePointerCoordinate(std.math.inf(f32), doubled));
    try std.testing.expectEqual(std.math.maxInt(i32), devicePointerCoordinate(std.math.floatMax(f32), doubled));
    try std.testing.expectEqual(std.math.minInt(i32), devicePointerCoordinate(-std.math.floatMax(f32), doubled));
}

test "every retained terminal input source defers an active-session change" {
    try std.testing.expect(!(TerminalInputDebt{}).remains());
    try std.testing.expect((TerminalInputDebt{ .encoded = 1 }).remains());
    try std.testing.expect((TerminalInputDebt{ .staged = 1 }).remains());
    try std.testing.expect((TerminalInputDebt{ .committed = 1 }).remains());
    try std.testing.expect((TerminalInputDebt{ .paste = true }).remains());
    try std.testing.expect((TerminalInputDebt{ .responses = 1 }).remains());
}

test "a deferred pane press cannot leak to the previously active terminal" {
    const clicked: workspace.PaneId = @enumFromInt(2);
    const previous: workspace.PaneId = @enumFromInt(1);
    try std.testing.expect(App.panePressRoutesToTerminal(clicked, clicked));
    try std.testing.expect(!App.panePressRoutesToTerminal(clicked, previous));
    try std.testing.expect(!App.panePressRoutesToTerminal(clicked, null));
}

test "a UI-owned pane gesture keeps held motion away from the terminal" {
    const inactive: workspace.PaneId = @enumFromInt(2);
    const focused: workspace.PaneId = @enumFromInt(1);
    const held: platform.ButtonsHeld = .{ .left = true };

    try std.testing.expect(App.paneMotionOwnedByUi(true, inactive, focused, held));
    try std.testing.expect(!App.paneMotionOwnedByUi(false, inactive, focused, held));
    try std.testing.expect(App.paneMotionOwnedByUi(false, inactive, focused, .{}));
    try std.testing.expect(!App.paneMotionOwnedByUi(false, focused, focused, held));
}

test "focused UI transition identity survives modifier and focus-order changes" {
    var state: UiKeyState = .{};
    const press = platform.KeyEvent{
        .action = .press,
        .mods = .{ .ctrl = true },
        .codepoint = 'x',
        .unshifted_codepoint = 'x',
    };
    const release = platform.KeyEvent{
        .action = .release,
        .mods = .{},
        .codepoint = 'x',
        .unshifted_codepoint = 'x',
    };
    const identity = uiKeyIdentity(press).?;
    try std.testing.expect(uiKeyIdentityEql(identity, uiKeyIdentity(release).?));
    try std.testing.expect(state.claim(identity, .none));
    try std.testing.expect(state.indexOf(uiKeyIdentity(release).?) != null);
    try std.testing.expect(!state.claim(identity, .none));
    state.release(state.indexOf(identity).?);
    try std.testing.expectEqual(@as(usize, 0), state.len);

    const tab = uiKeyIdentity(.{ .action = .press, .key = .tab }).?;
    const enter = uiKeyIdentity(.{ .action = .press, .key = .enter }).?;
    try std.testing.expect(!uiKeyIdentityEql(tab, enter));
}

test "focused UI ownership refuses a full inline state atomically" {
    var state: UiKeyState = .{};
    var index: usize = 0;
    while (index < ui_key_capacity) : (index += 1) {
        try std.testing.expect(state.claim(.{ .character = @intCast(index + 1) }, .none));
    }
    try std.testing.expect(!state.claim(.{ .character = 0x10ffff }, .none));
    try std.testing.expectEqual(ui_key_capacity, state.len);
}

test "search shortcuts are modal, platform-specific, and action-named" {
    const linux_open = platform.KeyEvent{
        .action = .press,
        .mods = .{ .ctrl = true, .shift = true },
        .codepoint = 'F',
        .unshifted_codepoint = 'f',
    };
    const mac_open = platform.KeyEvent{
        .action = .press,
        .mods = .{ .super = true },
        .codepoint = 'f',
        .unshifted_codepoint = 'f',
    };
    try std.testing.expectEqualStrings(search_open_action, searchKeyAction(.linux_windows, false, linux_open).?);
    try std.testing.expect(searchKeyAction(.macos, false, linux_open) == null);
    try std.testing.expectEqualStrings(search_open_action, searchKeyAction(.macos, false, mac_open).?);
    try std.testing.expect(searchKeyAction(.linux_windows, false, mac_open) == null);

    try std.testing.expectEqualStrings(search_next_action, searchKeyAction(.linux_windows, true, .{
        .action = .press,
        .key = .enter,
    }).?);
    try std.testing.expectEqualStrings(search_previous_action, searchKeyAction(.linux_windows, true, .{
        .action = .press,
        .key = .f3,
        .mods = .{ .shift = true },
    }).?);
    try std.testing.expectEqualStrings(search_case_action, searchKeyAction(.linux_windows, true, .{
        .action = .press,
        .mods = .{ .alt = true },
        .unshifted_codepoint = 'c',
    }).?);
    try std.testing.expectEqualStrings(search_regex_action, searchKeyAction(.linux_windows, true, .{
        .action = .press,
        .mods = .{ .alt = true },
        .unshifted_codepoint = 'r',
    }).?);
    try std.testing.expectEqualStrings(search_close_action, searchKeyAction(.linux_windows, true, .{
        .action = .press,
        .key = .escape,
    }).?);
    try std.testing.expect(searchKeyAction(.linux_windows, false, .{
        .action = .press,
        .key = .enter,
    }) == null);
}

test "search navigation wraps and semantic match ids are bounded" {
    try std.testing.expectEqual(@as(usize, 0), nextSearchIndex(0, 0, true));
    try std.testing.expectEqual(@as(usize, 1), nextSearchIndex(0, 3, true));
    try std.testing.expectEqual(@as(usize, 0), nextSearchIndex(2, 3, true));
    try std.testing.expectEqual(@as(usize, 2), nextSearchIndex(0, 3, false));
    try std.testing.expectEqual(@as(usize, 1), nextSearchIndex(2, 3, false));
    try std.testing.expectEqual(@as(usize, 12), App.searchMatchSemanticIndex("search.match.12.99").?);
    try std.testing.expect(App.searchMatchSemanticIndex("search.match.bad.99") == null);
    try std.testing.expect(App.searchMatchSemanticIndex("terminal.match.12.99") == null);
}

test "completed and exhausted searches stop requesting polling ticks" {
    try std.testing.expect(searchWorkPending(true, true, false, .running, false));
    try std.testing.expect(searchWorkPending(true, true, false, .complete, true));
    try std.testing.expectEqual(term.SearchProgress.running, searchVisibleProgress(.complete, true));
    try std.testing.expectEqual(term.SearchProgress.running, searchVisibleProgress(.running, false));
    try std.testing.expectEqual(term.SearchProgress.complete, searchVisibleProgress(.complete, false));
    try std.testing.expect(!searchWorkPending(true, true, false, .complete, false));
    try std.testing.expect(!searchWorkPending(true, true, false, .scratch_exhausted, false));
    try std.testing.expect(searchWorkPending(true, true, true, .scratch_exhausted, false));
}

test "search bar keeps a usable Input on every nonzero canvas" {
    const full = calculateSearchBarLayout(.{ .x = 0, .y = 0, .width = 100, .height = 24 }).?;
    try std.testing.expect(full.bordered);
    try std.testing.expectEqual(ui.Rect{ .x = 28, .y = 0, .width = 72, .height = 4 }, full.bounds);
    try std.testing.expectEqual(ui.Rect{ .x = 30, .y = 1, .width = 68, .height = 1 }, full.query);
    try std.testing.expectEqual(ui.Rect{ .x = 30, .y = 2, .width = 68, .height = 1 }, full.detail.?);

    const narrow = calculateSearchBarLayout(.{ .x = 0, .y = 0, .width = 41, .height = 4 }).?;
    try std.testing.expect(!narrow.bordered);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .width = 41, .height = 4 }, narrow.bounds);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 0, .width = 41, .height = 1 }, narrow.query);
    try std.testing.expectEqual(ui.Rect{ .x = 0, .y = 1, .width = 41, .height = 1 }, narrow.detail.?);

    const short = calculateSearchBarLayout(.{ .x = 3, .y = 2, .width = 2, .height = 1 }).?;
    try std.testing.expect(!short.bordered);
    try std.testing.expectEqual(ui.Rect{ .x = 3, .y = 2, .width = 2, .height = 1 }, short.query);
    try std.testing.expect(short.detail == null);

    const one_cell = calculateSearchBarLayout(.{ .x = 7, .y = 9, .width = 1, .height = 1 }).?;
    try std.testing.expectEqual(ui.Rect{ .x = 7, .y = 9, .width = 1, .height = 1 }, one_cell.query);
    try std.testing.expect(calculateSearchBarLayout(.{ .x = 0, .y = 0, .width = 0, .height = 4 }) == null);
    try std.testing.expect(calculateSearchBarLayout(.{ .x = 0, .y = 0, .width = 4, .height = 0 }) == null);
}
