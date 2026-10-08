//! Conduit's seam for every OS call: the window, the GL context, and the events.
//!
//! **Owns** window creation, the GL context, the HiDPI scale, event translation and clipboard
//! access (TASK-15). **Never** contains product logic, layout or workspace behaviour, and never
//! lets an OS handle escape above this file.
//! **May depend on** `std`, the SDL3 seam and the embedded window-icon pixels only.
//!
//! TASK-7 owns what is here now: a real window with a real GL context, a hidden-but-real mode
//! (doc-2: headless is a peer of the on-screen path, never a second renderer), and the
//! translation of SDL's events into Conduit's own. Everything above this file knows a `State` and
//! an `Event`; nothing above it knows an `SDL_Event`.
//!
//! TASK-12 owns the input half: what a key press and an input method's composition arrive as, and
//! the four calls through which the OS is asked for text at all — start it, stop it, and tell it
//! where the text is. Those are OS differences (an OS with an input method attached has one, a
//! headless CI box does not), which is why they are here and not in `input`: everything above this
//! file says *what* to point at, and never *how*.
//!
//! A `Window` owns GL object names and SDL handles rather than heap memory. `DriverTransport` is
//! the exception: it owns its endpoint name, worker thread and bounded cross-thread message
//! queues, and makes every allocation and ownership transfer explicit at that boundary.

const std = @import("std");
const sdl = @import("sdl");
const builtin = @import("builtin");
const window_icon = @import("window-icon");

/// The log scope for platform failures. Every line platform logs goes through a scope and never
/// straight to a stream.
pub const log = std.log.scoped(.platform);

/// The OpenGL version Conduit asks every window for (decision-2: OpenGL 3.3 core, so the grid and
/// UI renderers and the FBO all speak one dialect).
pub const gl_major_version: c_int = 3;
pub const gl_minor_version: c_int = 3;

/// Resolve one OpenGL entry point through SDL.
///
/// The return type is `zopengl.LoaderFn`, spelled out here so that `platform` never imports
/// `zopengl` — that import belongs to `render`, which is the module that loads the bindings.
/// `render` passes this function straight to `zopengl.loadCoreProfile`.
///
/// SDL only answers for the *current* context, so this is unusable until a context is current.
pub fn glProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    const raw = sdl.SDL_GL_GetProcAddress(name) orelse return null;
    return @ptrCast(raw);
}

/// The last error SDL recorded, as text.
///
/// SDL reports failure through a per-thread string rather than a return value. The text is copied
/// into `buffer` because SDL's own buffer is only valid until the next SDL call. Returns
/// `"(no SDL error)"` when SDL has nothing to say, so a log line never carries a dangling pointer.
pub fn lastError(buffer: []u8) []const u8 {
    const raw = sdl.SDL_GetError() orelse return "(no SDL error)";
    const text = std.mem.span(raw);
    if (text.len == 0) return "(no SDL error)";
    const kept = @min(text.len, buffer.len);
    @memcpy(buffer[0..kept], text[0..kept]);
    return buffer[0..kept];
}

// ---------------------------------------------------------------------------
// Window icon
// ---------------------------------------------------------------------------

/// The window icon's edge length in pixels. The embedded fixture is exactly this square in RGBA8.
pub const window_icon_size: usize = 64;

/// Give the window Conduit's icon, so a task switcher shows it even where no desktop entry is
/// installed (on X11, SDL publishes it as `_NET_WM_ICON`). An icon is cosmetic: a refusal is
/// logged and the window carries on without one.
fn setWindowIcon(handle: *sdl.SDL_Window) void {
    // SDL's signature takes mutable pixels, but a surface made from caller memory is only read
    // here: `SDL_SetWindowIcon` converts and copies it, and the surface is destroyed before
    // returning, so the embedded constant is never written.
    const surface = sdl.SDL_CreateSurfaceFrom(
        @as(c_int, @intCast(window_icon_size)),
        @as(c_int, @intCast(window_icon_size)),
        sdl.SDL_PIXELFORMAT_RGBA32,
        @constCast(window_icon.rgba.ptr),
        @as(c_int, @intCast(window_icon_size * 4)),
    ) orelse {
        var buffer: [256]u8 = undefined;
        log.warn("window icon surface could not be created: {s}", .{lastError(&buffer)});
        return;
    };
    defer sdl.SDL_DestroySurface(surface);
    if (!sdl.SDL_SetWindowIcon(handle, surface)) {
        var buffer: [256]u8 = undefined;
        log.warn("SDL_SetWindowIcon failed: {s}", .{lastError(&buffer)});
    }
}

// ---------------------------------------------------------------------------
// Windows window integration (TASK-49)
// ---------------------------------------------------------------------------

/// The Win32 calls behind the Windows-only window features: the dark title bar, the DPI
/// awareness report and giving back a console nobody asked for.
///
/// SDL owns the window; this only borrows its HWND (`SDL_PROP_WINDOW_WIN32_HWND_POINTER`). DWM and
/// the DPI query are looked up at run time, as SDL does, so a Windows without them (a Server Core
/// image, Windows 10 before 1607) gets an ordinary window and a log line instead of a failed load.
/// Main thread only, like every SDL window call.
const windows_window = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const HWND = *anyopaque;
    const HMODULE = *anyopaque;

    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?HMODULE;
    extern "kernel32" fn GetProcAddress(module: HMODULE, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn GetConsoleProcessList(list: [*]u32, count: u32) callconv(.winapi) u32;
    extern "kernel32" fn FreeConsole() callconv(.winapi) windows.BOOL;

    /// `DWMWA_USE_IMMERSIVE_DARK_MODE`: 20 since Windows 10 20H1 (19041); 19 before it.
    const dwmwa_use_immersive_dark_mode: u32 = 20;
    const dwmwa_use_immersive_dark_mode_legacy: u32 = 19;

    const DwmSetWindowAttribute = *const fn (HWND, u32, *const anyopaque, u32) callconv(.winapi) i32;
    const GetThreadDpiAwarenessContext = *const fn () callconv(.winapi) ?*anyopaque;
    const GetAwarenessFromDpiAwarenessContext = *const fn (?*anyopaque) callconv(.winapi) i32;
    const GetDpiForWindow = *const fn (HWND) callconv(.winapi) u32;

    fn hwnd(handle: *sdl.SDL_Window) ?HWND {
        const properties = sdl.SDL_GetWindowProperties(handle);
        return sdl.SDL_GetPointerProperty(properties, "SDL.window.win32.hwnd", null);
    }

    fn function(comptime T: type, library: []const u8, name: [*:0]const u8) ?T {
        var wide: [32:0]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(&wide, library) catch return null; // a fixed, short DLL name
        wide[length] = 0;
        const module = LoadLibraryW(wide[0..length :0]) orelse return null;
        const address = GetProcAddress(module, name) orelse return null;
        return @ptrCast(address);
    }

    /// Ask DWM to draw the title bar dark or light. Returns whether DWM accepted either spelling.
    fn setDarkTitleBar(handle: *sdl.SDL_Window, dark: bool) bool {
        const window = hwnd(handle) orelse return false;
        const set = function(DwmSetWindowAttribute, "dwmapi.dll", "DwmSetWindowAttribute") orelse return false;
        const value: windows.BOOL = if (dark) .TRUE else .FALSE;
        if (set(window, dwmwa_use_immersive_dark_mode, &value, @sizeOf(windows.BOOL)) >= 0) return true;
        return set(window, dwmwa_use_immersive_dark_mode_legacy, &value, @sizeOf(windows.BOOL)) >= 0;
    }

    /// The thread's DPI awareness as SDL left it (it declares per-monitor v2 when the manifest
    /// has not), and the window's own DPI, for the log.
    fn logDpi(handle: *sdl.SDL_Window) void {
        const awareness: []const u8 = blk: {
            const get_context = function(GetThreadDpiAwarenessContext, "user32.dll", "GetThreadDpiAwarenessContext") orelse break :blk "unknown";
            const get_awareness = function(GetAwarenessFromDpiAwarenessContext, "user32.dll", "GetAwarenessFromDpiAwarenessContext") orelse break :blk "unknown";
            break :blk switch (get_awareness(get_context())) {
                0 => "unaware",
                1 => "system",
                2 => "per-monitor",
                else => "invalid",
            };
        };
        const dpi: u32 = blk: {
            const window = hwnd(handle) orelse break :blk 0;
            const get_dpi = function(GetDpiForWindow, "user32.dll", "GetDpiForWindow") orelse break :blk 0;
            break :blk get_dpi(window);
        };
        log.info("windows dpi awareness {s}, window dpi {d}", .{ awareness, dpi });
    }

    /// Give back the console Windows made for this process, when nobody else is using it.
    ///
    /// `conduit.exe` is a console-subsystem program, so `conduit --version` prints in the shell
    /// that ran it. Started from Explorer or a shortcut, though, Windows also creates a console
    /// window for it, which would sit behind Conduit's own window for its whole life. A console
    /// whose process list holds only this process is that one, and it is released once the window
    /// exists; a console shared with a parent shell (or a test harness) is left alone.
    fn releaseOwnConsole() void {
        var processes: [2]u32 = undefined;
        if (GetConsoleProcessList(&processes, processes.len) == 1) {
            _ = FreeConsole();
            log.info("released the console window Windows created for this process", .{});
        }
    }
} else struct {};

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

/// The largest clipboard payload Conduit accepts from the OS or offers to it.
/// Clipboard traffic is user/request driven, but it is still external input
/// and may not make the process allocate without a fixed upper bound.
pub const max_clipboard_bytes: usize = 8 * 1024 * 1024;

/// Native primary selection exists on Conduit's Linux targets (X11 and
/// Wayland). SDL provides a process-local fallback elsewhere, but input must
/// not advertise middle-click paste where the OS has no primary selection.
pub const primary_selection_supported = builtin.os.tag == .linux;

/// Why a native text clipboard operation was refused.
pub const ClipboardError = Allocator.Error || error{
    PayloadTooLarge,
    InvalidText,
    ClipboardReadFailed,
    ClipboardWriteFailed,
};

const Allocator = std.mem.Allocator;

/// Whether the standard system clipboard currently holds non-empty text.
pub fn hasClipboardText() bool {
    return sdl.SDL_HasClipboardText();
}

/// Copy UTF-8 `text` to the standard system clipboard.
///
/// `alloc` owns the temporary NUL-terminated copy required by SDL and is
/// released before this function returns. Embedded NUL and invalid UTF-8 are
/// refused rather than silently truncated or handed to a platform backend.
pub fn setClipboardText(alloc: Allocator, text: []const u8) ClipboardError!void {
    try validateClipboardText(text);
    const terminated = try alloc.dupeZ(u8, text);
    defer alloc.free(terminated);
    if (!sdl.SDL_SetClipboardText(terminated.ptr)) return error.ClipboardWriteFailed;
}

/// Read the standard system clipboard as UTF-8.
///
/// The returned slice is allocated by `alloc`; the caller owns it and must
/// free it with that same allocator. SDL's native allocation is always freed
/// before this function returns.
pub fn getClipboardText(alloc: Allocator) ClipboardError![]u8 {
    const raw = sdl.SDL_GetClipboardText() orelse return error.ClipboardReadFailed;
    defer sdl.SDL_free(raw);
    return copyClipboardText(alloc, std.mem.span(raw));
}

/// Whether Linux's primary selection currently holds non-empty text.
///
/// SDL keeps a process-local fallback on other operating systems, but callers
/// should consult `primary_selection_supported` before presenting this as a
/// native user action.
pub fn hasPrimarySelectionText() bool {
    return sdl.SDL_HasPrimarySelectionText();
}

/// Copy UTF-8 `text` to Linux's X11/Wayland primary selection.
///
/// `alloc` owns only the temporary NUL-terminated copy. The same validation
/// and 8 MiB bound as the standard clipboard apply.
pub fn setPrimarySelectionText(alloc: Allocator, text: []const u8) ClipboardError!void {
    try validateClipboardText(text);
    const terminated = try alloc.dupeZ(u8, text);
    defer alloc.free(terminated);
    if (!sdl.SDL_SetPrimarySelectionText(terminated.ptr)) return error.ClipboardWriteFailed;
}

/// Read Linux's X11/Wayland primary selection as UTF-8.
///
/// The returned slice is allocated by `alloc`; the caller owns it and must
/// free it with that same allocator. SDL's native allocation is freed here.
pub fn getPrimarySelectionText(alloc: Allocator) ClipboardError![]u8 {
    const raw = sdl.SDL_GetPrimarySelectionText() orelse return error.ClipboardReadFailed;
    defer sdl.SDL_free(raw);
    return copyClipboardText(alloc, std.mem.span(raw));
}

fn validateClipboardText(text: []const u8) ClipboardError!void {
    if (text.len > max_clipboard_bytes) return error.PayloadTooLarge;
    if (std.mem.indexOfScalar(u8, text, 0) != null or
        !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
}

fn copyClipboardText(alloc: Allocator, text: []const u8) ClipboardError![]u8 {
    try validateClipboardText(text);
    return alloc.dupe(u8, text);
}

/// The desktop's light/dark preference, as far as the platform reports it.
pub const SystemTheme = enum { unknown, light, dark };

/// The desktop's current light/dark preference. `unknown` when the platform does not report one
/// (X11 without a desktop portal, for example) or before a window exists.
pub fn systemTheme() SystemTheme {
    return systemThemeFrom(sdl.SDL_GetSystemTheme());
}

fn systemThemeFrom(raw: sdl.SDL_SystemTheme) SystemTheme {
    return switch (raw) {
        sdl.SDL_SYSTEM_THEME_LIGHT => .light,
        sdl.SDL_SYSTEM_THEME_DARK => .dark,
        else => .unknown,
    };
}

/// The name of the video driver SDL is running on (`x11`, `wayland`, `offscreen`, ...), or null
/// before a window exists. Which clipboard a run reaches depends on it: `offscreen` and `dummy`
/// keep SDL's process-local clipboard, the display drivers reach the display's.
pub fn videoDriverName() ?[]const u8 {
    const name = sdl.SDL_GetCurrentVideoDriver() orelse return null;
    return std.mem.span(name);
}

/// Make SDL use `name` as its video driver, over `SDL_VIDEO_DRIVER` too, for every window this
/// process creates from now on. Call before the first window.
///
/// `--clipboard-test` uses it to pin itself to `offscreen`, whose clipboard and primary selection
/// are SDL's own process-local copies: a check that writes known fixtures must never reach the
/// clipboard of a display a person is using.
pub fn forceVideoDriver(name: [:0]const u8) bool {
    return sdl.SDL_SetHintWithPriority(sdl.SDL_HINT_VIDEO_DRIVER, name, sdl.SDL_HINT_OVERRIDE);
}

/// Product identity passed to SDL before any subsystem is initialized.
///
/// The caller owns all three NUL-terminated strings and lends them for `setAppMetadata`; this
/// platform seam retains no pointer. It deliberately imposes no product name, version scheme or
/// reverse-domain identifier policy.
pub const AppMetadata = struct {
    /// Human-readable application name.
    name: [:0]const u8,
    /// Caller-selected release version or build identifier.
    version: [:0]const u8,
    /// Stable caller-selected application identifier.
    identifier: [:0]const u8,
};

/// Why SDL refused application metadata.
pub const AppMetadataError = error{MetadataRejected};

/// Give SDL the application's identity before initializing its video subsystem.
///
/// Call this before `Window.create`; some platform backends consume identity only during
/// initialization. Repeating the call is supported by SDL, although already-initialized backend
/// state may retain the earlier identity.
pub fn setAppMetadata(metadata: AppMetadata) AppMetadataError!void {
    _ = sdl.SDL_ClearError();
    if (!applyAppMetadata(metadata, sdl.SDL_SetAppMetadata)) {
        var buffer: [256]u8 = undefined;
        log.err("SDL_SetAppMetadata failed: {s}", .{lastError(&buffer)});
        return error.MetadataRejected;
    }
}

fn applyAppMetadata(metadata: AppMetadata, setter: anytype) bool {
    return setter(metadata.name.ptr, metadata.version.ptr, metadata.identifier.ptr);
}

/// SDL input-method UI that Conduit renders itself.
///
/// This exact declaration must be installed before SDL initializes a video backend. On Linux it
/// lets SDL's IBus integration keep composition and candidate UI in Conduit's semantic/rendering
/// path instead of asking a desktop toolkit Conduit does not use to provide native widgets.
const implemented_ime_ui: [:0]const u8 = "composition,candidates";

fn applyImplementedImeUiHint(setter: anytype) bool {
    // This hint describes UI that Conduit actually implements; it is not a
    // user preference. Environment variables have SDL's override priority,
    // so normal priority would make an exported value turn capability setup
    // into a fatal window-start failure instead of declaring the truth.
    return setter(
        sdl.SDL_HINT_IME_IMPLEMENTED_UI,
        implemented_ime_ui.ptr,
        sdl.SDL_HINT_OVERRIDE,
    );
}

const ImeUiHintError = error{ImeUiHintRejected};

fn setImplementedImeUiHintWith(setter: anytype) ImeUiHintError!void {
    if (!applyImplementedImeUiHint(setter)) return error.ImeUiHintRejected;
}

fn setImplementedImeUiHint() ImeUiHintError!void {
    _ = sdl.SDL_ClearError();
    setImplementedImeUiHintWith(sdl.SDL_SetHintWithPriority) catch |err| {
        var buffer: [256]u8 = undefined;
        log.err("SDL_SetHint(IME_IMPLEMENTED_UI) failed: {s}", .{lastError(&buffer)});
        return err;
    };
}

/// Largest HTTP or HTTPS target the platform will hand to the desktop.
///
/// This matches the terminal link detector's default bound without importing that higher layer.
/// The fixed limit prevents an untrusted terminal from turning one click into an unbounded
/// temporary allocation.
pub const max_open_url_bytes: usize = 2048;

/// Why an explicit URL could not be opened.
pub const OpenUrlError = Allocator.Error || error{
    UrlTooLong,
    InvalidUtf8,
    UnsupportedScheme,
    InvalidUrl,
    ControlCharacter,
    OpenFailed,
};

/// Ask the desktop to open one explicitly user-activated HTTP or HTTPS target.
///
/// Gesture policy belongs to the caller: this function must be reached only from a direct user
/// action, never from terminal output alone. Validation is allocation-free and completes before
/// the one temporary NUL-terminated copy required by SDL. The URL is never logged.
pub fn openUrl(allocator: Allocator, url: []const u8) OpenUrlError!void {
    try validateOpenUrl(url);
    const terminated = try allocator.dupeZ(u8, url);
    defer allocator.free(terminated);

    if (!sdl.SDL_OpenURL(terminated.ptr)) {
        log.err("SDL_OpenURL failed", .{});
        return error.OpenFailed;
    }
}

fn validateOpenUrl(url: []const u8) OpenUrlError!void {
    if (url.len > max_open_url_bytes) return error.UrlTooLong;
    if (url.len == 0) return error.InvalidUrl;

    const view = std.unicode.Utf8View.init(url) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (codepoint < 0x20 or (codepoint >= 0x7f and codepoint < 0xa0) or
            codepoint == 0x2028 or codepoint == 0x2029)
        {
            return error.ControlCharacter;
        }
        if (codepoint == ' ') return error.InvalidUrl;
    }

    const scheme_len: usize = if (url.len >= 8 and std.ascii.eqlIgnoreCase(url[0..8], "https://"))
        8
    else if (url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "http://"))
        7
    else
        return error.UnsupportedScheme;

    var authority_end = scheme_len;
    while (authority_end < url.len) : (authority_end += 1) {
        const byte = url[authority_end];
        if (byte == '/' or byte == '?' or byte == '#') break;
    }
    var authority = url[scheme_len..authority_end];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (authority.len == 0 or authority[0] == ':' or authority[0] == '.') {
        return error.InvalidUrl;
    }
}

// Desktop notifications (TASK-56) -------------------------------------------------------------

/// The most bytes of a notification title or body handed to the desktop. The caller has already
/// cleaned and bounded the text; these limits only refuse something that was not.
pub const max_notify_title_bytes: usize = 256;
pub const max_notify_body_bytes: usize = 1024;
/// How long one Linux notification may take before its helper is killed.
pub const notify_timeout_ms: u32 = 5000;

/// Why an OS notification was not shown.
pub const NotifyError = Allocator.Error || error{
    /// This platform has no notification backend yet (macOS and Windows, until TASK-48 and
    /// TASK-49 give them one).
    Unsupported,
    /// The helper (`notify-send` on Linux) is not installed.
    Unavailable,
    /// Text over its bound, not valid UTF-8, or with a control character.
    InvalidText,
    /// The helper ran and failed, or did not finish within `notify_timeout_ms`.
    Failed,
};

/// Show one desktop notification with `title` and `body`.
///
/// Blocks until the helper finishes or `notify_timeout_ms` passes, so it is for worker threads
/// only, never the render thread. Linux runs `notify-send --app-name=Conduit -- <title> <body>`
/// as argv (no shell), so notification text can never become a command; macOS and Windows
/// return `error.Unsupported` for now. Neither text is logged.
pub fn notify(allocator: Allocator, io: std.Io, title: []const u8, body: []const u8) NotifyError!void {
    try validateNotifyText(title, max_notify_title_bytes);
    try validateNotifyText(body, max_notify_body_bytes);
    switch (builtin.os.tag) {
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => return notifyFreedesktop(allocator, io, title, body),
        else => return error.Unsupported,
    }
}

fn validateNotifyText(text: []const u8, limit: usize) NotifyError!void {
    if (text.len > limit or !std.unicode.utf8ValidateSlice(text)) return error.InvalidText;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return error.InvalidText;
    }
}

fn notifyFreedesktop(allocator: Allocator, io: std.Io, title: []const u8, body: []const u8) NotifyError!void {
    // An OSC 9 notification has no title; the desktop needs a summary line.
    const summary = if (title.len == 0) "Conduit" else title;
    var child = std.process.spawn(io, .{
        .argv = &.{ "notify-send", "--app-name=Conduit", "--", summary, body },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| return switch (err) {
        error.FileNotFound => error.Unavailable,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Failed,
    };
    // Kills and reaps a helper still running on any early return; after `wait` it does nothing.
    defer child.kill(io);
    const deadline = (std.Io.Timeout{ .duration = .{
        .raw = .fromMilliseconds(notify_timeout_ms),
        .clock = .awake,
    } }).toDeadline(io);
    var streams_buffer: std.Io.File.MultiReader.Buffer(1) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, streams_buffer.toStreams(), &.{child.stdout.?});
    defer multi_reader.deinit();
    // notify-send prints nothing unless asked to; reading to the end of its stdout is how the
    // wait is bounded without blocking in `wait` on a helper stuck on D-Bus.
    while (multi_reader.fill(1, deadline)) |_| {
        multi_reader.reader(0).tossBuffered();
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.Failed,
    }
    const status = child.wait(io) catch return error.Failed;
    switch (status) {
        .exited => |code| if (code != 0) return error.Failed,
        else => return error.Failed,
    }
}

/// Why a window could not be created, changed or driven.
///
/// Every value here is the operating system, a window manager or a driver refusing something. All
/// of them are returned and logged, never asserted on (CONDUIT.md §11).
pub const WindowError = error{
    /// SDL has no video subsystem at all: no display server, or the video driver refused.
    VideoUnavailable,
    /// SDL would not create the window.
    WindowCreationFailed,
    /// The window exists but the GL context does not: no driver, or no driver new enough.
    ContextCreationFailed,
    /// The window exists and SDL refused the new size.
    ResizeFailed,
    /// SDL refused an event pushed into its own queue.
    EventPostFailed,
    /// SDL could not reserve collision-free application event ids.
    EventRegistrationFailed,
    /// The OS refused to turn text input on or off, or would not take the area Conduit asked for.
    TextInputUnavailable,
};

// ---------------------------------------------------------------------------
// The scale rule
// ---------------------------------------------------------------------------

/// A display scale factor: how many physical pixels one logical pixel covers.
///
/// Whatever convention a platform uses to report scale is normalised here once. The only OS
/// conditionals Conduit permits are the ones that *select* a backend (P12); nothing above this file
/// knows a scale came from an OS.
///
/// Invariant: `factor` is finite and at least `min_factor`. A scale that is zero, negative, NaN or
/// infinite resolves to `default_factor` instead of reaching the renderer and producing a surface
/// with no pixels in it.
pub const Scale = struct {
    /// The number of physical pixels per logical pixel.
    factor: f32,

    /// The scale used when the platform reports nothing usable. One physical pixel per logical
    /// pixel is the only value always safe to draw at.
    pub const default_factor: f32 = 1.0;

    /// The smallest factor `fromPlatform` accepts. Below it a window would be smaller than any
    /// display can show.
    pub const min_factor: f32 = 0.1;

    /// Normalise a scale reported by the OS. Non-finite values and values below `min_factor`
    /// resolve to `default_factor`.
    pub fn fromPlatform(reported: f32) Scale {
        if (!std.math.isFinite(reported) or reported < min_factor) {
            return .{ .factor = default_factor };
        }
        return .{ .factor = reported };
    }

    /// Convert a length in logical pixels to physical pixels.
    ///
    /// A scale below one is legitimate — a fractional-scale display really does have fewer physical
    /// pixels than logical ones — so this does not clamp up to `logical`. It clamps to one pixel,
    /// because a drawable surface of zero pixels is not a surface.
    pub fn toPhysical(self: Scale, logical: u32) u32 {
        const scaled = @as(f64, @floatFromInt(logical)) * @as(f64, self.factor);
        const rounded: u32 = @intFromFloat(@round(scaled));
        return @max(rounded, @as(u32, 1));
    }
};

/// Choose the scale a window uses for its next state.
///
/// A fixed scale is already a normalised `Scale` and always wins. Without one, every display
/// report still passes through the platform scale rule before it reaches layout or rendering.
fn selectScale(fixed: ?Scale, reported: f32) Scale {
    return fixed orelse Scale.fromPlatform(reported);
}

/// A size in logical pixels: the size a window was asked for.
///
/// A logical size is what the user sees and what every layout calculation produces. It is
/// deliberately platform-free; converting it to physical pixels is `platform`'s job and goes
/// through `SurfaceSize.fromLogical`.
pub const LogicalSize = struct {
    width: u32,
    height: u32,
};

/// A size in physical pixels: the size of a drawable surface.
///
/// Invariant: both dimensions are at least one pixel. A window with a zero-area drawable surface is
/// not a window, and letting one exist is how a renderer ends up dividing by a zero cell size.
pub const SurfaceSize = struct {
    width_px: u32,
    height_px: u32,

    /// The smallest surface that exists. Anything smaller is clamped up to it.
    pub const min_dimension: u32 = 1;

    /// Build a surface size from physical pixels, clamping each dimension up to `min_dimension`.
    pub fn init(width_px: u32, height_px: u32) SurfaceSize {
        return .{
            .width_px = @max(width_px, min_dimension),
            .height_px = @max(height_px, min_dimension),
        };
    }

    /// The surface a window of `logical` pixels needs at `scale`.
    pub fn fromLogical(logical: LogicalSize, scale: Scale) SurfaceSize {
        return .{
            .width_px = scale.toPhysical(logical.width),
            .height_px = scale.toPhysical(logical.height),
        };
    }
};

/// Everything Conduit knows about a window at one moment: the size the user sees, the display
/// scale, and the drawable surface that follows from the two.
///
/// `surface` is always `SurfaceSize.fromLogical(logical, scale)`. There is exactly one way a
/// surface size is computed in Conduit, and this is it — a window whose size and scale are known
/// has exactly one surface, and every consumer of that number gets the same one.
pub const State = struct {
    /// The size in logical pixels: what the user sees, and what layout is computed in.
    logical: LogicalSize,
    /// The normalised display scale in force.
    scale: Scale,
    /// The drawable surface, derived from the two above.
    surface: SurfaceSize,

    /// The state a window of `logical` pixels is in at `scale`.
    pub fn init(logical: LogicalSize, scale: Scale) State {
        return .{
            .logical = logical,
            .scale = scale,
            .surface = SurfaceSize.fromLogical(logical, scale),
        };
    }

    /// The same window at a new display scale: same logical size, new surface.
    ///
    /// This is what a DPI change does. The logical size is untouched by a scale change, so the
    /// surface is recomputed from the size that was already true.
    pub fn rescaled(self: State, scale: Scale) State {
        return State.init(self.logical, scale);
    }
};

// ---------------------------------------------------------------------------
// Keyboard and text input
// ---------------------------------------------------------------------------

/// What happened to a key: it went down, came up, or repeated because it is being held.
///
/// Kept because the Kitty keyboard protocol can be asked to report the difference (a terminal option
/// that costs one escape sequence to set) and because a renderer needs to know whether a key was
/// pressed again. Everything above this file never sees an OS event type.
pub const KeyAction = enum {
    /// The key went down.
    press,
    /// The key came up.
    release,
    /// The key went down again because it is being held.
    repeat,
};

/// The modifiers that were down when a key was reported.
///
/// A terminal encoder needs all six, including the two locks: a program reading the keypad with
/// NumLock on has to be able to tell, and CapsLock decides whether ctrl+A is the same key as ctrl+a.
/// Which *side* a modifier came from is deliberately not here — nothing above `platform` reads it,
/// and macOS Option-as-Alt (TASK-37) is the one place that will.
pub const Mods = packed struct(u6) {
    /// Control.
    ctrl: bool = false,
    /// Alt, called option on macOS.
    alt: bool = false,
    /// Shift. The keyboard has already applied it to the character it reports.
    shift: bool = false,
    /// The command key: cmd on macOS, the Windows key elsewhere.
    super: bool = false,
    /// Caps lock.
    caps_lock: bool = false,
    /// Num lock.
    num_lock: bool = false,
};

/// The keys a terminal has to tell apart, named for what they do rather than for where they sit.
///
/// Layout-independent by construction: `.enter` is the enter key on every layout. They are exactly
/// the keys that have no character of their own — the navigation block, the editing keys and the
/// function row — because for every other key the operating system has already produced the
/// character the layout asked for, and that character is what the terminal wants.
///
/// This is deliberately *not* a copy of a keyboard. It is the set a terminal program binds by
/// escape sequence, and a key outside it is `.unidentified` rather than a guess.
pub const Key = enum {
    /// A key with no name here: a media key, an international key, a keypad key, a modifier.
    unidentified,
    enter,
    tab,
    backspace,
    escape,
    insert,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

/// One key transition, as the operating system reported it.
///
/// The character is *not* the key: `codepoint` is what the layout produced with every modifier
/// applied, and `unshifted_codepoint` is the same key with shift and caps lock taken back off.
/// Both are zero for a key that has no character, and both are filtered here — an OS keycode above
/// the Unicode range is SDL naming a modifier, not a character, and letting it through would put a
/// value in a field that promises a codepoint.
pub const KeyEvent = struct {
    /// What happened to the key.
    action: KeyAction,
    /// Which key it was, layout-independent.
    key: Key = .unidentified,
    /// The modifiers that were down with it.
    mods: Mods = .{},
    /// The layout's codepoint with every modifier applied, or 0 for a key with no character.
    codepoint: u21 = 0,
    /// The layout's codepoint with shift and caps lock *not* applied, or 0.
    unshifted_codepoint: u21 = 0,
    /// macOS only (TASK-48): Option is held as a character level, not as Alt, so the character
    /// comes from the text input that follows and the terminal must not encode this key. Always
    /// false on other OSes and whenever `macos.option_as_alt` makes the held Option Alt.
    option_composes: bool = false,
};

/// What an input method is composing: the text it wants shown, and the selection inside it.
///
/// This is a *preedit*. It is text the user has typed but has not committed, so it belongs on screen
/// and nowhere else — it is never written to the child's input, which is a property of the key
/// encoder rather than a check anyone has to remember (see `term.KeyPress.composing`).
///
/// `start` and `length` are byte offsets into `text`, clamped to its length by `editing`: an input
/// method is an untrusted source like any other, and an offset past the end of its own buffer would
/// be a slice of whatever follows it in memory.
pub const TextEditing = struct {
    /// The text being composed. Empty when the input method has nothing pending, which is how a
    /// composition ends.
    text: []const u8 = "",
    /// The byte offset the selection starts at, never past `text`.
    start: u32 = 0,
    /// How many bytes of `text` are selected, never past the end.
    length: u32 = 0,

    /// The composition an input method described, with its offsets made safe.
    ///
    /// SDL reports -1 for "no selection" and an input method can report a range its own text does
    /// not contain; both resolve to a selection at the start of the text rather than to an index
    /// into memory it does not own.
    pub fn editing(text: []const u8, start: i32, length: i32) TextEditing {
        const length_u32: u32 = @intCast(text.len);
        const safe_start: u32 = if (start <= 0)
            0
        else
            @min(@as(u32, @intCast(start)), length_u32);
        const safe_length: u32 = if (length <= 0)
            0
        else
            @min(@as(u32, @intCast(length)), length_u32 - safe_start);
        return .{ .text = text, .start = safe_start, .length = safe_length };
    }

    /// Whether this composition selects nothing.
    pub fn isCursorOnly(self: TextEditing) bool {
        return self.length == 0;
    }
};

/// The alternatives an input method is offering for the text being composed.
///
/// The strings are *copied into the value* rather than borrowed. An input method's candidates are
/// the one piece of input whose lifetime does not match the event's: SDL frees the array of
/// pointers as soon as the event has been read, so borrowing it would mean the app held a list of
/// pointers into freed memory between one event and the next. Copying costs a fixed, bounded
/// amount — a candidate list arrives a few times per keystroke, not once per frame — and it makes
/// the value safe to hand to a renderer that draws it on the next frame.
///
/// A list longer than `capacity`, or an entry longer than `max_length`, is truncated and
/// `truncated` says so: an input method is untrusted input like any other, and neither bound is a
/// number it gets to choose.
pub const Candidates = struct {
    /// How many candidates one list can hold.
    pub const capacity: usize = 9;
    /// The longest candidate kept, in bytes. Cut on a codepoint boundary, so what survives is text.
    pub const max_length: usize = 64;

    /// The candidate text, laid end to end.
    storage: [capacity][max_length]u8 = @splat(@as([max_length]u8, @splat(0))),
    /// How many bytes of each entry of `storage` are text.
    lengths: [capacity]u8 = @splat(0),
    /// How many entries of `storage` are candidates.
    count: u8 = 0,
    /// The candidate in focus, or null when the input method has not chosen one — which is not the
    /// same as choosing the first.
    selected: ?u8 = null,
    /// Whether the input method wants them drawn in a row rather than a column.
    horizontal: bool = false,
    /// Whether anything was dropped to fit the bounds above.
    truncated: bool = false,

    /// The candidate list an input method described, copied in and with its index made safe.
    ///
    /// A negative or out-of-range selection becomes no selection, which is what an input method
    /// means by -1 and what an out-of-range index can only mean by accident.
    pub fn candidates(
        list: []const []const u8,
        selected: i32,
        horizontal: bool,
    ) Candidates {
        var out: Candidates = .{};
        var index: usize = 0;
        for (list) |item| {
            if (out.count == capacity) {
                out.truncated = true;
                break;
            }
            const kept = utf8Prefix(item, max_length);
            @memcpy(out.storage[index][0..kept], item[0..kept]);
            out.lengths[index] = @intCast(kept);
            index += 1;
            out.count += 1;
            if (kept != item.len) out.truncated = true;
        }
        out.selected = if (selected < 0 or @as(usize, @intCast(selected)) >= out.count)
            null
        else
            @as(u8, @intCast(selected));
        out.horizontal = horizontal;
        return out;
    }

    /// The candidate at `index`, in the order the input method ranked them.
    ///
    /// One at a time, not as a slice of slices: the slices would have to point
    /// into this value's own storage, and a slice of them built on the stack
    /// would be dangling the moment this function returned. A renderer walks
    /// the list with `len` and `get`.
    pub fn get(self: *const Candidates, index: usize) ?[]const u8 {
        if (index >= @min(self.count, capacity)) return null;
        return self.storage[index][0..self.lengths[index]];
    }

    /// How many candidates there are.
    pub fn len(self: *const Candidates) usize {
        return @min(self.count, capacity);
    }

    /// The candidate in focus, or null when there is none.
    pub fn current(self: *const Candidates) ?[]const u8 {
        const index = self.selected orelse return null;
        return self.get(index);
    }

    /// The longest prefix of `bytes` that fits in `limit` bytes and is still whole text.
    ///
    /// Copying half a codepoint would produce a string that is not a string; an input method that
    /// offers more than `max_length` bytes for one candidate gets the part that is.
    fn utf8Prefix(bytes: []const u8, limit: usize) usize {
        if (bytes.len <= limit) return bytes.len;
        var kept: usize = limit;
        // Walk back over continuation bytes to the start of the last codepoint that fits.
        while (kept > 0 and bytes[kept] & 0xc0 == 0x80) kept -= 1;
        return if (kept == 0) limit else kept;
    }
};

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// A scroll wheel or a trackpad event, in the units the device reported.
///
/// The three extra facts are the device's, and they are kept rather than folded into a line count
/// because each one changes the answer and only the terminal knows the rules:
///
/// - `precise` separates a trackpad (a distance) from a notched wheel (a count). Treating a
///   trackpad's tenths of a pixel as notches makes it scroll either not at all or far too fast.
/// - `flipped` is macOS natural scrolling, which inverts the axis. X11 has no such mode, so a
///   terminal that ignored it would scroll the wrong way on one platform and be blamed on the
///   other.
/// - the pointer position travels with the event because a mouse report is about a place, and the
///   place is where the wheel was, not where the pointer happened to be when the event was read.
///
/// `x` and `y` are floats even for a notched wheel: SDL reports the accumulated fractional travel
/// and the pointer's window coordinates in the same event, and a layer that rounded them here
/// would have to round them back to get the position.
pub const Wheel = struct {
    /// Horizontal travel, positive to the right. The terminal has no horizontal history in v0.1
    /// and ignores this; it is carried so a caller can see the device reported it.
    dx: f32 = 0,
    /// Vertical travel, positive away from the user — back into history.
    dy: f32 = 0,
    /// Whether the device reported sub-notch travel. A trackpad and a high-resolution wheel do;
    /// a notched wheel does not, and reports whole steps instead.
    precise: bool = false,
    /// Whether the platform inverted the vertical axis for this event.
    flipped: bool = false,
    /// Where the pointer is, in window pixels, relative to the window's top left.
    x: f32 = 0,
    y: f32 = 0,
};

/// A pointer button a mouse or trackpad has.
///
/// Only the three X11 buttons are modelled, because those are the three the
/// X10 mouse protocol has codes for; a side button has no code in any format
/// Ghostty's encoder speaks and is dropped rather than encoded as something a
/// program would read as a left click.
pub const MouseButton = enum {
    left,
    middle,
    right,
};

/// The pointer buttons down at the moment an event was reported.
///
/// Carried on motion rather than tracked here: SDL reports the button mask with
/// every motion event, and a layer that kept its own count would disagree with
/// the device the first time a button was released outside the window.
pub const ButtonsHeld = packed struct(u3) {
    left: bool = false,
    middle: bool = false,
    right: bool = false,
};

/// One pointer button going down or coming up, with the place it happened.
///
/// The same three extra facts `Wheel` carries travel here — modifiers, because a
/// report carries them and Shift is how the user overrides a program that has
/// captured the mouse, and the position, because a report is about a place. The
/// action reuses `KeyAction` rather than a second enum: a button press and a key
/// press are the same transition, and a caller that handled one and not the other
/// would be surprising.
pub const PointerButton = struct {
    /// Which button moved.
    button: MouseButton,
    /// Whether it went down or came up.
    action: KeyAction,
    /// The modifiers that were down with it.
    mods: Mods = .{},
    /// Where the pointer is, in window pixels, relative to the window's top left.
    x: f32 = 0,
    y: f32 = 0,
};

/// The pointer moved, with the place it moved to and what was held.
///
/// Motion is reported even when no button is down because a program in any-event
/// mode (DECSET 1003) is asking for exactly that, and dropping it here would
/// leave the mode unimplemented rather than merely unused.
pub const PointerMotion = struct {
    /// The modifiers that were down with it.
    mods: Mods = .{},
    /// Which buttons were down.
    buttons: ButtonsHeld = .{},
    /// Where the pointer is, in window pixels, relative to the window's top left.
    x: f32 = 0,
    y: f32 = 0,
};

/// What the app is told happened.
///
/// An `Event` is a fact about this window or its keyboard, not a record of what SDL said: the
/// translation has already happened, so nothing above this file branches on an OS event type. The
/// text an event carries borrows SDL's memory and stays valid only until the next SDL call, so a
/// consumer that needs to keep it copies it (see `input.Composition`).
///
/// The input variants are delivered through the same `Window.pump` as the window ones. Splitting
/// them into a second queue would mean the app had to poll two things to notice that something
/// happened, and one of them would get the events the other had already taken.
pub const Event = union(enum) {
    /// The window's logical size changed. The state is the window at its new size.
    resized: State,
    /// The display reported a different scale. `state` is the same window at the newly reported
    /// scale, and `previous` is the scale it had before, so a handler can tell a scale change that
    /// actually moved the surface from one that did not.
    scale_changed: struct { state: State, previous: Scale },
    /// The window gained keyboard focus.
    focused,
    /// The window lost keyboard focus.
    unfocused,
    /// The window was shown, uncovered or restored: whatever is on screen may be stale.
    exposed,
    /// The window manager asked for the window to close.
    close_requested,
    /// The application was asked to quit.
    quit,
    /// The local test-driver worker made one or more requests available.
    driver_wake,
    /// Every previously posted synthetic input event has passed through SDL's FIFO queue.
    driver_barrier: u32,
    /// The desktop's light/dark preference changed; `systemTheme` reads the new one.
    system_theme_changed,
    /// The native clipboard changed. `owned` distinguishes a change made by
    /// this process from one made by another application without exposing SDL.
    clipboard_updated: struct { owned: bool },
    /// A key went down, came up, or repeated. The one input event a terminal cannot do without.
    key: KeyEvent,
    /// Text was committed: typed on a plain keyboard, or confirmed by an input method. This is the
    /// only text that reaches the child.
    text_input: []const u8,
    /// An input method's composition changed: the preedit to show, and where its selection is.
    text_editing: TextEditing,
    /// An input method's candidate list changed.
    candidates: Candidates,
    /// A pointer button went down or came up. The position travels with it because
    /// a mouse report is about a place, and so is a selection anchor.
    mouse_button: PointerButton,
    /// The pointer moved. Delivered whether or not a button is down, because
    /// any-event mode (DECSET 1003) is asking for precisely the case where none
    /// is.
    mouse_motion: PointerMotion,
    /// A scroll wheel or a trackpad. The units are the device's, deliberately: how many pixels or
    /// notches one event is worth is a mapping the terminal owns, and a platform layer that
    /// decided it here would decide it twice.
    wheel: Wheel,
};

/// The collision-free SDL event ids reserved for one Conduit window.
const DriverEventTypes = struct {
    wake: SdlEventType,
    barrier: SdlEventType,
};

/// An SDL event type as a plain unsigned integer.
///
/// The translated headers type `SDL_Event.type` as an unsigned 32-bit integer while every event
/// constant is a `c_int`. The two are made comparable once here: the value arrives as this type and
/// the switch prongs convert the constant.
const SdlEventType = u32;

/// The type of `raw` as `SdlEventType`.
fn eventType(raw: sdl.SDL_Event) SdlEventType {
    return @intCast(raw.type);
}

/// Whether `kind` is one of the event families that can change the window's geometry, and so
/// require asking the OS what the window looks like before the event is translated.
///
/// The pixel-size event is in this list even though Conduit derives the surface from the logical
/// size: it is the signal a driver sends when the drawable moved for a reason the logical size does
/// not show, and ignoring it is how a stale FBO survives a display change.
fn changesGeometry(kind: SdlEventType) bool {
    return switch (kind) {
        @intCast(sdl.SDL_EVENT_WINDOW_RESIZED),
        @intCast(sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED),
        @intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_CHANGED),
        @intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED),
        => true,
        else => false,
    };
}

/// Whether `kind` belongs to the window-event family at all.
fn isWindowEvent(kind: SdlEventType) bool {
    const first: SdlEventType = @intCast(sdl.SDL_EVENT_WINDOW_FIRST);
    const last: SdlEventType = @intCast(sdl.SDL_EVENT_WINDOW_LAST);
    return kind >= first and kind <= last;
}

/// Whether `kind` belongs to the keyboard, pointer or text-input family.
///
/// Pointer events are named here rather than left to the window-event test
/// because they are input about this window's surface, not about its geometry,
/// and a pointer event that arrived for another window must not reach a
/// terminal.
fn isInputEvent(kind: SdlEventType) bool {
    return switch (kind) {
        @intCast(sdl.SDL_EVENT_KEY_DOWN),
        @intCast(sdl.SDL_EVENT_KEY_UP),
        @intCast(sdl.SDL_EVENT_TEXT_INPUT),
        @intCast(sdl.SDL_EVENT_TEXT_EDITING),
        @intCast(sdl.SDL_EVENT_TEXT_EDITING_CANDIDATES),
        @intCast(sdl.SDL_EVENT_MOUSE_WHEEL),
        @intCast(sdl.SDL_EVENT_MOUSE_MOTION),
        @intCast(sdl.SDL_EVENT_MOUSE_BUTTON_DOWN),
        @intCast(sdl.SDL_EVENT_MOUSE_BUTTON_UP),
        => true,
        else => false,
    };
}

/// The Conduit key an SDL scancode names, or `.unidentified` for a key outside the set.
///
/// A switch over the scancodes rather than an `@enumFromInt` in both directions, so a scancode SDL
/// adds is a compile error here instead of a key that silently encodes as nothing.
fn keyFromScancode(scancode: sdl.SDL_Scancode) Key {
    return switch (scancode) {
        sdl.SDL_SCANCODE_RETURN, sdl.SDL_SCANCODE_KP_ENTER => .enter,
        sdl.SDL_SCANCODE_TAB => .tab,
        sdl.SDL_SCANCODE_BACKSPACE => .backspace,
        sdl.SDL_SCANCODE_ESCAPE => .escape,
        sdl.SDL_SCANCODE_INSERT => .insert,
        sdl.SDL_SCANCODE_DELETE => .delete,
        sdl.SDL_SCANCODE_UP => .up,
        sdl.SDL_SCANCODE_DOWN => .down,
        sdl.SDL_SCANCODE_LEFT => .left,
        sdl.SDL_SCANCODE_RIGHT => .right,
        sdl.SDL_SCANCODE_HOME => .home,
        sdl.SDL_SCANCODE_END => .end,
        sdl.SDL_SCANCODE_PAGEUP => .page_up,
        sdl.SDL_SCANCODE_PAGEDOWN => .page_down,
        sdl.SDL_SCANCODE_F1 => .f1,
        sdl.SDL_SCANCODE_F2 => .f2,
        sdl.SDL_SCANCODE_F3 => .f3,
        sdl.SDL_SCANCODE_F4 => .f4,
        sdl.SDL_SCANCODE_F5 => .f5,
        sdl.SDL_SCANCODE_F6 => .f6,
        sdl.SDL_SCANCODE_F7 => .f7,
        sdl.SDL_SCANCODE_F8 => .f8,
        sdl.SDL_SCANCODE_F9 => .f9,
        sdl.SDL_SCANCODE_F10 => .f10,
        sdl.SDL_SCANCODE_F11 => .f11,
        sdl.SDL_SCANCODE_F12 => .f12,
        else => .unidentified,
    };
}

/// SDL's layout-independent scancode for one of Conduit's named keys.
fn scancodeFromKey(key: Key) sdl.SDL_Scancode {
    return switch (key) {
        .unidentified => sdl.SDL_SCANCODE_UNKNOWN,
        .enter => sdl.SDL_SCANCODE_RETURN,
        .tab => sdl.SDL_SCANCODE_TAB,
        .backspace => sdl.SDL_SCANCODE_BACKSPACE,
        .escape => sdl.SDL_SCANCODE_ESCAPE,
        .insert => sdl.SDL_SCANCODE_INSERT,
        .delete => sdl.SDL_SCANCODE_DELETE,
        .up => sdl.SDL_SCANCODE_UP,
        .down => sdl.SDL_SCANCODE_DOWN,
        .left => sdl.SDL_SCANCODE_LEFT,
        .right => sdl.SDL_SCANCODE_RIGHT,
        .home => sdl.SDL_SCANCODE_HOME,
        .end => sdl.SDL_SCANCODE_END,
        .page_up => sdl.SDL_SCANCODE_PAGEUP,
        .page_down => sdl.SDL_SCANCODE_PAGEDOWN,
        .f1 => sdl.SDL_SCANCODE_F1,
        .f2 => sdl.SDL_SCANCODE_F2,
        .f3 => sdl.SDL_SCANCODE_F3,
        .f4 => sdl.SDL_SCANCODE_F4,
        .f5 => sdl.SDL_SCANCODE_F5,
        .f6 => sdl.SDL_SCANCODE_F6,
        .f7 => sdl.SDL_SCANCODE_F7,
        .f8 => sdl.SDL_SCANCODE_F8,
        .f9 => sdl.SDL_SCANCODE_F9,
        .f10 => sdl.SDL_SCANCODE_F10,
        .f11 => sdl.SDL_SCANCODE_F11,
        .f12 => sdl.SDL_SCANCODE_F12,
    };
}

/// The character a keycode stands for, or 0 when it is not one.
///
/// SDL reports a modifier key as a constant far above the Unicode range — `SDLK_LCTRL` is
/// 0x40000000 — and those are names for keys, not characters. Only a real scalar survives, so a
/// field that promises a codepoint cannot be handed a keycode.
fn codepointFromKeycode(key: sdl.SDL_Keycode) u21 {
    if (key == 0) return 0;
    return std.math.cast(u21, key) orelse 0;
}

/// The modifiers SDL reported, in Conduit's own set.
fn modsFrom(keymod: sdl.SDL_Keymod) Mods {
    return .{
        .ctrl = keymod & sdl.SDL_KMOD_CTRL != 0,
        .alt = keymod & sdl.SDL_KMOD_ALT != 0,
        .shift = keymod & sdl.SDL_KMOD_SHIFT != 0,
        .super = keymod & sdl.SDL_KMOD_GUI != 0,
        .caps_lock = keymod & sdl.SDL_KMOD_CAPS != 0,
        .num_lock = keymod & sdl.SDL_KMOD_NUM != 0,
    };
}

/// Conduit's modifiers as SDL's, for the one place Conduit imposes them rather
/// than reads them.
///
/// `modsFrom` is the direction that matters at runtime. This one exists because
/// `Window.postPointerButton` has to produce an event SDL's own translation will
/// carry the modifiers on, and SDL 3.2's button events have nowhere to put them.
fn modsToSdl(mods: Mods) sdl.SDL_Keymod {
    var keymod: sdl.SDL_Keymod = 0;
    if (mods.ctrl) keymod |= sdl.SDL_KMOD_CTRL;
    if (mods.alt) keymod |= sdl.SDL_KMOD_ALT;
    if (mods.shift) keymod |= sdl.SDL_KMOD_SHIFT;
    if (mods.super) keymod |= sdl.SDL_KMOD_GUI;
    if (mods.caps_lock) keymod |= sdl.SDL_KMOD_CAPS;
    if (mods.num_lock) keymod |= sdl.SDL_KMOD_NUM;
    return keymod;
}

/// The keycode this layout produces for `scancode` with shift and caps lock taken off.
///
/// SDL asks the active keyboard layout, so this is the layout's answer rather than Conduit's: on a
/// layout where shift is something other than a case change, the two codepoints differ exactly when
/// the layout says they do. Zero when the layout has no answer, which is a key with no character.
fn unshiftedCodepoint(scancode: sdl.SDL_Scancode, mods: sdl.SDL_Keymod) u21 {
    const without = mods & ~(@as(sdl.SDL_Keymod, sdl.SDL_KMOD_SHIFT) | @as(sdl.SDL_Keymod, sdl.SDL_KMOD_CAPS));
    return codepointFromKeycode(sdl.SDL_GetKeyFromScancode(scancode, without, false));
}

/// The modifiers that choose a key's shift level rather than command it: Shift, Caps Lock, AltGr
/// (SDL's Mode) and Level 5. Ctrl, Alt and Super stay out because what they do to a character is
/// the encoder's decision, not the layout's.
const level_mods: sdl.SDL_Keymod = @as(sdl.SDL_Keymod, sdl.SDL_KMOD_SHIFT) | @as(sdl.SDL_Keymod, sdl.SDL_KMOD_CAPS) |
    @as(sdl.SDL_Keymod, sdl.SDL_KMOD_MODE) | @as(sdl.SDL_Keymod, sdl.SDL_KMOD_LEVEL5);

/// The character the layout puts on `scancode` with the level-selecting modifiers applied.
///
/// SDL 3.4 does not apply modifiers to a key event's own `key` — it is the unmodified keycode, so
/// Shift+h reports `h` — while the text input SDL sends next carries `H`. Reading `key` made the
/// key path write `h` and the text echo then commit `H` as well. The layout is asked again here
/// with the level modifiers, which is the same table lookup `unshiftedCodepoint` makes.
fn layoutCodepoint(scancode: sdl.SDL_Scancode, mods: sdl.SDL_Keymod) u21 {
    return codepointFromKeycode(sdl.SDL_GetKeyFromScancode(scancode, mods & level_mods, false));
}

/// One SDL keyboard event as Conduit's own key event.
///
/// `option_as_alt` only matters on macOS, where it decides `option_composes` (TASK-48).
fn keyEvent(raw: sdl.SDL_KeyboardEvent, option_as_alt: OptionAsAlt) KeyEvent {
    const action: KeyAction = if (!raw.down) .release else if (raw.repeat) .repeat else .press;
    var event: KeyEvent = .{
        .action = action,
        .key = keyFromScancode(raw.scancode),
        .mods = modsFrom(raw.mod),
        .codepoint = layoutCodepoint(raw.scancode, raw.mod),
        .unshifted_codepoint = unshiftedCodepoint(raw.scancode, raw.mod),
    };
    if (builtin.os.tag == .macos) event.option_composes = optionComposes(event, raw.mod, option_as_alt);
    return event;
}

/// Which macOS Option keys act as Alt: the `macos.option_as_alt` setting (TASK-48).
///
/// macOS convention is that Option is a character level (Option+e is a dead acute accent,
/// Option+x is `≈`), which is `none` and the default. A terminal user who wants Meta asks for
/// `both`, or for one side so the other still composes. Inert on every other OS.
pub const OptionAsAlt = enum {
    /// Both Option keys compose characters.
    none,
    /// The left Option key is Alt; the right one composes.
    left,
    /// The right Option key is Alt; the left one composes.
    right,
    /// Both Option keys are Alt.
    both,

    /// SDL's spelling of the same choice, for `SDL_HINT_MAC_OPTION_AS_ALT`.
    fn sdlHint(self: OptionAsAlt) [:0]const u8 {
        return switch (self) {
            .none => "none",
            .left => "only_left",
            .right => "only_right",
            .both => "both",
        };
    }
};

/// Whether the Option key held for `keymod` acts as Alt under `mode`.
///
/// Sided like SDL's own hint: with `left`, only a held left Option is Alt. When both Options
/// are held, either configured side is enough, which is also how SDL decides whether to strip
/// Option's composition from the text it sends.
fn optionActsAsAlt(keymod: sdl.SDL_Keymod, mode: OptionAsAlt) bool {
    const left = keymod & sdl.SDL_KMOD_LALT != 0;
    const right = keymod & sdl.SDL_KMOD_RALT != 0;
    return switch (mode) {
        .none => false,
        .left => left,
        .right => right,
        .both => left or right,
    };
}

/// Whether this press is Option composing a character rather than Alt (macOS only).
///
/// It is when Option is held on a side that is not configured as Alt, on a key with a
/// character, with neither Command nor Control: then the character is the text system's
/// (Option+x arrives as `≈` in the text input that follows, Option+e starts a dead key), so the
/// terminal must take it from there and not encode the key itself. A named key (Option+Left) and
/// a command chord (Command+Option+Left) keep Option as a modifier, as they do in every macOS
/// terminal. Bindings still see the modifier: only the encoding changes (`input.translate`).
fn optionComposes(event: KeyEvent, keymod: sdl.SDL_Keymod, mode: OptionAsAlt) bool {
    if (!event.mods.alt) return false;
    if (event.key != .unidentified) return false;
    if (event.mods.ctrl or event.mods.super) return false;
    if (event.unshifted_codepoint == 0) return false;
    return !optionActsAsAlt(keymod, mode);
}

/// Whether an input event belongs to this window.
///
/// SDL reports window id 0 for input that arrived with no window at all, which belongs to whoever
/// has focus rather than to nobody, so it is accepted rather than dropped.
fn isForWindow(id: sdl.SDL_WindowID, window_id: sdl.SDL_WindowID) bool {
    return id == 0 or id == window_id;
}

/// One raw SDL wheel event as Conduit's own.
///
/// SDL 3 delivers a notched wheel and a trackpad through the same event, and the two are told apart
/// by whether the travel it reports is a whole number: a notched wheel steps by whole notches, and
/// a precise device reports the distance its fingers travelled. That is the whole of the rule, and
/// it is a rule rather than a flag because SDL 3 dropped the separate precise event that SDL 2 had.
fn wheelEvent(raw: sdl.SDL_MouseWheelEvent) Wheel {
    const fractional = raw.x != @trunc(raw.x) or raw.y != @trunc(raw.y);
    return .{
        .dx = raw.x,
        .dy = raw.y,
        .precise = fractional,
        .flipped = raw.direction == sdl.SDL_MOUSEWHEEL_FLIPPED,
        .x = raw.mouse_x,
        .y = raw.mouse_y,
    };
}

/// The Conduit button an SDL button constant names, or null for one no mouse
/// report format has a code for.
///
/// An SDL side button (4 and up) and a wheel, which arrives as its own event,
/// both land here. Neither has a code in X10, SGR or urxvt, so they are dropped
/// rather than folded into a button a program would read as a click.
fn mouseButtonFrom(button: u8) ?MouseButton {
    return switch (button) {
        sdl.SDL_BUTTON_LEFT => .left,
        sdl.SDL_BUTTON_MIDDLE => .middle,
        sdl.SDL_BUTTON_RIGHT => .right,
        else => null,
    };
}

/// The buttons SDL's button mask holds down.
fn buttonsFrom(state: u32) ButtonsHeld {
    return .{
        .left = state & sdl.SDL_BUTTON_LMASK != 0,
        .middle = state & sdl.SDL_BUTTON_MMASK != 0,
        .right = state & sdl.SDL_BUTTON_RMASK != 0,
    };
}

/// One raw SDL button event as Conduit's own, or null when the button is one no
/// report format codes.
fn pointerButtonEvent(raw: sdl.SDL_MouseButtonEvent) ?PointerButton {
    const button = mouseButtonFrom(raw.button) orelse return null;
    return .{
        .button = button,
        .action = if (raw.down) .press else .release,
        // SDL 3.2 dropped the modifier field from its button events. The
        // keyboard's current modifier state is where a report's shift bit comes
        // from, and SDL maintains it from the key events that arrive before the
        // button does. It is the same answer for a real hand and for a posted
        // event, because `Window.postPointer` sets the same state a key press
        // would (CONDUIT.md §7 relies on it: shift overrides a program's mouse
        // capture).
        .mods = modsFrom(sdl.SDL_GetModState()),
        .x = @floatCast(raw.x),
        .y = @floatCast(raw.y),
    };
}

/// One raw SDL motion event as Conduit's own, or null when the pointer is not
/// over this window.
///
/// SDL reports FLT_MAX for both coordinates once the pointer has left every
/// window, with a window id of 0. Those events exist so a window that cares can
/// notice the pointer left; a terminal that turned one into a cell would report a
/// motion at a cell that does not exist, so they are dropped here.
fn pointerMotionEvent(raw: sdl.SDL_MouseMotionEvent, window_id: sdl.SDL_WindowID) ?PointerMotion {
    if (!isForWindow(raw.windowID, window_id)) return null;
    if (!isRealCoordinate(@as(f32, @floatCast(raw.x))) or
        !isRealCoordinate(@as(f32, @floatCast(raw.y)))) return null;
    return .{
        .mods = modsFrom(sdl.SDL_GetModState()),
        .buttons = buttonsFrom(raw.state),
        .x = @floatCast(raw.x),
        .y = @floatCast(raw.y),
    };
}

/// Whether a coordinate is a real place rather than the sentinel SDL leaves
/// behind when it has nowhere to say the pointer is.
///
/// The sentinel is `FLT_MAX`, which is a perfectly ordinary finite float — a
/// test that only asked "is this a number?" would wave it through and the app
/// would report a mouse at a cell three hundred million columns to the right. So
/// the test is a *range*: every real coordinate is below the largest float, and
/// an infinity or a NaN is below nothing.
fn isRealCoordinate(value: f32) bool {
    return value < std.math.floatMax(f32);
}

/// Turn one raw keyboard, text or input-method event into Conduit's own, or `null` when it is not
/// this window's.
///
/// Every union member is read only inside the prong for its own event type: `SDL_Event` is a union,
/// and reading the wrong member is undefined behaviour in C and a panic in a safe build. The type
/// is therefore switched on before anything is looked at.
fn translateInput(raw: sdl.SDL_Event, window_id: sdl.SDL_WindowID, option_as_alt: OptionAsAlt) ?Event {
    return switch (eventType(raw)) {
        @intCast(sdl.SDL_EVENT_KEY_DOWN),
        @intCast(sdl.SDL_EVENT_KEY_UP),
        => if (isForWindow(raw.key.windowID, window_id))
            .{ .key = keyEvent(raw.key, option_as_alt) }
        else
            null,
        @intCast(sdl.SDL_EVENT_MOUSE_WHEEL) => if (isForWindow(raw.wheel.windowID, window_id))
            .{ .wheel = wheelEvent(raw.wheel) }
        else
            null,
        @intCast(sdl.SDL_EVENT_MOUSE_BUTTON_DOWN),
        @intCast(sdl.SDL_EVENT_MOUSE_BUTTON_UP),
        => if (isForWindow(raw.button.windowID, window_id))
            if (pointerButtonEvent(raw.button)) |button| .{ .mouse_button = button } else null
        else
            null,
        @intCast(sdl.SDL_EVENT_MOUSE_MOTION) => if (pointerMotionEvent(raw.motion, window_id)) |motion|
            .{ .mouse_motion = motion }
        else
            null,
        @intCast(sdl.SDL_EVENT_TEXT_INPUT) => if (isForWindow(raw.text.windowID, window_id))
            .{ .text_input = if (raw.text.text) |text| std.mem.span(text) else "" }
        else
            null,
        @intCast(sdl.SDL_EVENT_TEXT_EDITING) => if (isForWindow(raw.edit.windowID, window_id))
            .{ .text_editing = TextEditing.editing(
                if (raw.edit.text) |text| std.mem.span(text) else "",
                raw.edit.start,
                raw.edit.length,
            ) }
        else
            null,
        @intCast(sdl.SDL_EVENT_TEXT_EDITING_CANDIDATES) => candidates: {
            if (!isForWindow(raw.edit_candidates.windowID, window_id)) break :candidates null;
            const borrowed = candidateItems(raw.edit_candidates);
            var list = Candidates.candidates(
                borrowed.slice(),
                raw.edit_candidates.selected_candidate,
                raw.edit_candidates.horizontal,
            );
            // What the handover had to leave behind is truncation of the
            // copied list too, or the copy is the only place the bound is
            // visible and it would show nine candidates as a complete list.
            if (borrowed.truncated) list.truncated = true;
            break :candidates .{ .candidates = list };
        },
        else => null,
    };
}

/// The candidate strings an input method event points at, borrowed.
///
/// SDL hands over a C array of C strings, which is not a slice of slices in Zig, so the pointers
/// are gathered into an array of borrowed slices here. They are only valid until the next SDL
/// call, which is exactly why `Candidates` copies them: this array is the handover, not the home.
/// A count larger than the capacity, or a null pointer in the middle of the list, is an input
/// method's mistake and is bounded rather than believed.
///
/// What is dropped here has to be reported, or a list that arrived long is copied and then
/// quietly looks complete: `truncated` is the difference between a renderer showing nine of
/// twenty alternatives and one that believes there were nine.
fn candidateItems(raw: sdl.SDL_TextEditingCandidatesEvent) BorrowedCandidates {
    var out: BorrowedCandidates = .{};
    if (raw.candidates == null or raw.num_candidates <= 0) return out;
    const claimed = @as(usize, @intCast(raw.num_candidates));
    const count = @min(claimed, BorrowedCandidates.capacity);
    out.truncated = claimed > count;
    for (raw.candidates[0..count]) |text| {
        if (text == null) {
            // An input method that offers a null string has offered a
            // candidate that cannot be shown, which is a dropped one.
            out.truncated = true;
            continue;
        }
        out.items[out.count] = std.mem.span(text);
        out.count += 1;
    }
    return out;
}

/// A candidate list borrowed from an input method, before it is copied.
const BorrowedCandidates = struct {
    /// How many borrowed slices fit. The same bound `Candidates` copies into, so the two agree
    /// about where the list ends.
    const capacity = Candidates.capacity;

    items: [capacity][]const u8 = @splat(&.{}),
    count: usize = 0,
    /// Whether anything the input method offered was left behind here.
    truncated: bool = false,

    /// The borrowed candidates.
    fn slice(self: *const BorrowedCandidates) []const []const u8 {
        return self.items[0..self.count];
    }
};

/// Turn one raw SDL event into Conduit's own event, or `null` when it is not Conduit's to act on:
/// an event for a different window, or one of the families Conduit does not consume yet (mouse,
/// joystick, touch).
///
/// Pure apart from one lookup: the unshifted codepoint of a key comes from SDL's keyboard layout
/// rather than from the event, because the layout is what knows it and the event only carries the
/// result of shift and caps lock having been applied. That lookup is a table read, and it is the
/// same one a real key press makes.
///
/// `before` is the window state before the event; `now` is the state re-read from the OS. They
/// differ only for an event that can change the geometry, which is exactly where the difference is
/// the payload.
pub fn translate(
    raw: sdl.SDL_Event,
    window_id: sdl.SDL_WindowID,
    before: State,
    now: State,
) ?Event {
    return translateWithDriverEvents(raw, window_id, before, now, null, .none);
}

/// Translate with the application-event ids owned by `Window`.
///
/// Keeping the ids as an explicit input preserves `translate` as the platform-neutral test seam:
/// SDL allocates these ids at runtime, so no global constant can identify them safely.
fn translateWithDriverEvents(
    raw: sdl.SDL_Event,
    window_id: sdl.SDL_WindowID,
    before: State,
    now: State,
    driver_events: ?DriverEventTypes,
    option_as_alt: OptionAsAlt,
) ?Event {
    const kind = eventType(raw);
    if (driver_events) |events| {
        if (kind == events.wake) {
            if (!isForWindow(raw.user.windowID, window_id)) return null;
            return .driver_wake;
        }
        if (kind == events.barrier) {
            if (!isForWindow(raw.user.windowID, window_id)) return null;
            return .{ .driver_barrier = @bitCast(raw.user.code) };
        }
    }
    // Quit belongs to the application, not to a window, so it is not filtered by window id.
    if (kind == @as(SdlEventType, @intCast(sdl.SDL_EVENT_CLIPBOARD_UPDATE))) {
        return .{ .clipboard_updated = .{ .owned = raw.clipboard.owner } };
    }
    if (kind == @as(SdlEventType, @intCast(sdl.SDL_EVENT_QUIT))) return .quit;
    // Like quit, the system theme belongs to the application, not to one window.
    if (kind == @as(SdlEventType, @intCast(sdl.SDL_EVENT_SYSTEM_THEME_CHANGED))) return .system_theme_changed;
    if (isInputEvent(kind)) return translateInput(raw, window_id, option_as_alt);
    if (!isWindowEvent(kind)) return null;
    if (raw.window.windowID != window_id) return null;

    return switch (kind) {
        @intCast(sdl.SDL_EVENT_WINDOW_RESIZED),
        @intCast(sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED),
        => .{ .resized = now },
        @intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED),
        @intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_CHANGED),
        => .{ .scale_changed = .{ .state = now, .previous = before.scale } },
        @intCast(sdl.SDL_EVENT_WINDOW_FOCUS_GAINED) => .focused,
        @intCast(sdl.SDL_EVENT_WINDOW_FOCUS_LOST) => .unfocused,
        // `shown` is an expose: the window has just become visible and nothing has been drawn
        // into it yet.
        @intCast(sdl.SDL_EVENT_WINDOW_EXPOSED),
        @intCast(sdl.SDL_EVENT_WINDOW_SHOWN),
        => .exposed,
        @intCast(sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED) => .close_requested,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// macOS application menu (TASK-48)
// ---------------------------------------------------------------------------

/// SDL's Cocoa backend builds a default menu bar when the app has none. Its Window menu gives
/// Close the key equivalent Command+W, and AppKit runs menu key equivalents *after* SDL has
/// already delivered the key: so Command+W, Conduit's `tab.close`, would close the tab and then
/// close the whole window too. `releaseCommandW` takes the equivalent off that item (the item
/// stays, clickable). Quit (Command+Q), Hide (Command+H), Minimize (Command+M) and Toggle Full
/// Screen (Control+Command+F) keep theirs: those are the platform's and Conduit binds none.
///
/// The Objective-C runtime is called directly, through `objc_msgSend` cast to each call's exact
/// C signature as arm64 requires. Everything here runs on the main thread after `SDL_Init`.
const macos_menu = if (builtin.os.tag == .macos) struct {
    const Id = ?*anyopaque;
    const Sel = ?*anyopaque;
    extern "c" fn objc_getClass(name: [*:0]const u8) Id;
    extern "c" fn sel_registerName(name: [*:0]const u8) Sel;
    extern "c" fn objc_msgSend() void;

    fn send(comptime Return: type, target: Id, selector: [*:0]const u8) Return {
        const function: *const fn (Id, Sel) callconv(.c) Return = @ptrCast(&objc_msgSend);
        return function(target, sel_registerName(selector));
    }

    fn sendArg(comptime Return: type, comptime Arg: type, target: Id, selector: [*:0]const u8, arg: Arg) Return {
        const function: *const fn (Id, Sel, Arg) callconv(.c) Return = @ptrCast(&objc_msgSend);
        return function(target, sel_registerName(selector), arg);
    }

    /// Remove Command+W from every menu item whose action is `performClose:`, and log how many
    /// items changed so a run shows whether SDL's menu looked the way it was expected to.
    fn releaseCommandW() void {
        const app = send(Id, objc_getClass("NSApplication"), "sharedApplication") orelse return;
        const menu_bar = send(Id, app, "mainMenu") orelse {
            log.info("macOS: no menu bar to adjust", .{});
            return;
        };
        const empty = send(Id, objc_getClass("NSString"), "string") orelse return;
        const close = sel_registerName("performClose:");
        var released: usize = 0;
        const menus: isize = send(isize, menu_bar, "numberOfItems");
        var index: isize = 0;
        while (index < menus) : (index += 1) {
            const item = sendArg(Id, isize, menu_bar, "itemAtIndex:", index) orelse continue;
            const submenu = send(Id, item, "submenu") orelse continue;
            const items: isize = send(isize, submenu, "numberOfItems");
            var inner: isize = 0;
            while (inner < items) : (inner += 1) {
                const entry = sendArg(Id, isize, submenu, "itemAtIndex:", inner) orelse continue;
                if (send(Sel, entry, "action") != close) continue;
                sendArg(void, Id, entry, "setKeyEquivalent:", empty);
                released += 1;
            }
        }
        log.info("macOS: released Command+W from {d} Close menu item(s)", .{released});
    }
} else struct {};

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

/// What Conduit asks a window for.
pub const WindowOptions = struct {
    /// NUL-terminated: SDL takes a C string, and Conduit does not allocate for it.
    title: [:0]const u8,
    /// The size in logical pixels the window is created at.
    logical: LogicalSize,
    /// Create the window hidden and never show it. The window and its GL context are real all the
    /// same (doc-2): headless is a peer of the on-screen path, not a second renderer.
    hidden: bool = false,
    /// Whether the user may resize the window. A terminal that cannot be resized is a screenshot.
    resizable: bool = true,
    /// Use this scale for the window instead of following the display.
    ///
    /// Deterministic headless runs set this so moving the hidden window between displays, or a
    /// compositor reporting a different scale, cannot change its framebuffer dimensions.
    fixed_scale: ?Scale = null,
};

fn windowCreationFlags(options: WindowOptions) u64 {
    var flags: u64 = sdl.SDL_WINDOW_OPENGL | sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY;
    if (options.resizable) flags |= sdl.SDL_WINDOW_RESIZABLE;
    if (options.hidden) flags |= sdl.SDL_WINDOW_HIDDEN;
    return flags;
}

/// Driver-reported facts about one live window, captured for diagnostics and platform evidence.
///
/// `video_backend` borrows SDL's process-global driver name and remains valid while the video
/// subsystem is initialized. Optional measurements are `null` when the active backend refuses
/// their query; no fallback or scale normalization is substituted for evidence.
pub const WindowRuntimeInfo = struct {
    /// Active SDL backend (`x11`, `wayland`, `offscreen`, ...).
    video_backend: ?[]const u8,
    /// Whether SDL reports that this window was created for a high-density back buffer.
    high_pixel_density: bool,
    /// Actual ratio of client-area pixels to logical window coordinates.
    pixel_density: ?f32,
    /// Current client-area size in logical window coordinates.
    logical_size: ?LogicalSize,
    /// Current drawable size in physical pixels.
    pixel_size: ?SurfaceSize,
};

fn reportedPixelDensity(value: f32) ?f32 {
    if (!std.math.isFinite(value) or value <= 0) return null;
    return value;
}

/// A rectangle in logical pixels, in window coordinates, with the origin at the top left.
///
/// Signed because SDL's own rectangle is signed and because an input method's candidate window may
/// legitimately sit above or left of this one — the rectangle Conduit tells it about is where the
/// text is, and where it draws that is the platform's business.
pub const LogicalRect = struct {
    /// The left edge, in logical pixels from the window's left.
    x: i32,
    /// The top edge, in logical pixels from the window's top.
    y: i32,
    /// The width in logical pixels.
    width: i32,
    /// The height in logical pixels.
    height: i32,

    /// The rectangle Conduit would describe for a cell at `column`/`row` of a grid whose cells are
    /// `cell` wide and tall, with the text cursor `cursor_bytes` into the cell.
    ///
    /// This is the rule every text-input area in Conduit is computed by, so the rectangle the input
    /// method is told about and the rectangle the renderer draws the cell at cannot drift apart.
    pub fn forCell(column: u32, row: u32, cell: LogicalSize, cursor_bytes: u32) LogicalRect {
        const x = std.math.mul(i32, @intCast(column), @intCast(cell.width)) catch 0;
        const y = std.math.mul(i32, @intCast(row), @intCast(cell.height)) catch 0;
        // The cursor offset is clamped to the cell: an offset past the cell would place the
        // candidate window outside the text it belongs to.
        const cursor = @min(cursor_bytes, cell.width);
        return .{
            .x = x + @as(i32, @intCast(cursor)),
            .y = y,
            .width = @intCast(cell.width),
            .height = @intCast(cell.height),
        };
    }
};

/// Where the OS is to put an input method's candidate window, and where the caret is inside it.
pub const TextArea = struct {
    /// The rectangle, in window coordinates.
    rect: LogicalRect,
    /// The byte offset of the caret into that rectangle's text.
    cursor: u32 = 0,
};

/// A real window with a real GL context, current on the thread that created it.
///
/// Ownership: the struct owns the SDL window, the GL context and SDL's video subsystem, and
/// `deinit` gives all three back in the reverse order it took them. It is passed around by
/// pointer: a copy would own the same handles twice.
pub const Window = struct {
    /// The SDL window, `null` once `deinit` has run.
    handle: ?*sdl.SDL_Window,
    /// The GL context, `null` once `deinit` has run.
    context: ?sdl.SDL_GLContext,
    /// SDL's id for this window, which every window event carries.
    id: sdl.SDL_WindowID,
    /// What Conduit last learned about the window's size and scale.
    state: State,
    /// A caller-selected scale which takes precedence over every later display report.
    fixed_scale: ?Scale,
    /// Whether this window is the one that started SDL's video subsystem.
    owns_video: bool,
    /// Runtime-reserved application events. They are per-window so no global registration race or
    /// hard-coded SDL user-event value can collide with another library in this process.
    driver_events: DriverEventTypes,
    /// Whether Conduit has asked the OS for text input on this window.
    ///
    /// Conduit's own answer rather than SDL's, because SDL's starts off: text input is off until
    /// something asks for it, and Conduit is what decides when.
    text_input: bool = false,
    /// The text input area Conduit last asked for, or null before it has asked once.
    ///
    /// Cached so that re-asserting it after a cursor move costs nothing when the cursor has not
    /// moved: the call is per-frame work otherwise, and the OS call behind it is not free.
    text_area: ?TextArea = null,
    /// Which macOS Option keys are Alt for key events from now on (`setOptionAsAlt`).
    option_as_alt: OptionAsAlt = .none,

    /// Create the window, its GL context and its scale, and leave the context current.
    ///
    /// Failures are returned, never asserted on: a machine with no display server, a driver that
    /// refuses a core profile and a compositor that refuses a window are all ordinary answers on
    /// somebody's computer.
    pub fn create(options: WindowOptions) !Window {
        try setImplementedImeUiHint();
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) {
            log.err("SDL_Init(VIDEO) failed: no video subsystem", .{});
            return error.VideoUnavailable;
        }
        errdefer sdl.SDL_Quit();

        const first_driver_event = sdl.SDL_RegisterEvents(2);
        if (first_driver_event == std.math.maxInt(u32)) {
            log.err("SDL_RegisterEvents(2) failed", .{});
            return error.EventRegistrationFailed;
        }
        const driver_events: DriverEventTypes = .{
            .wake = first_driver_event,
            .barrier = first_driver_event + 1,
        };

        // The GL attributes are requested before the window exists, because SDL creates the
        // context with it. Each one is a request to the driver, not a guarantee: what was actually
        // created is what `render.load` finds out and logs.
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MAJOR_VERSION, gl_major_version);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_CONTEXT_MINOR_VERSION, gl_minor_version);
        _ = sdl.SDL_GL_SetAttribute(
            sdl.SDL_GL_CONTEXT_PROFILE_MASK,
            sdl.SDL_GL_CONTEXT_PROFILE_CORE,
        );
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DOUBLEBUFFER, 1);
        // The FBO the renderer draws into has no depth or stencil and no samples: a multisampled
        // framebuffer cannot be read back with `glReadPixels` at all.
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_DEPTH_SIZE, 0);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_STENCIL_SIZE, 0);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_MULTISAMPLEBUFFERS, 0);
        _ = sdl.SDL_GL_SetAttribute(sdl.SDL_GL_MULTISAMPLESAMPLES, 0);
        const handle = sdl.SDL_CreateWindow(
            options.title,
            @as(c_int, @intCast(options.logical.width)),
            @as(c_int, @intCast(options.logical.height)),
            windowCreationFlags(options),
        ) orelse {
            var buffer: [256]u8 = undefined;
            log.err("SDL_CreateWindow({s}, {d}x{d}{s}) failed: {s}", .{
                options.title,
                options.logical.width,
                options.logical.height,
                if (options.hidden) ", hidden" else "",
                lastError(&buffer),
            });
            return error.WindowCreationFailed;
        };
        errdefer sdl.SDL_DestroyWindow(handle);
        setWindowIcon(handle);
        if (builtin.os.tag == .macos) macos_menu.releaseCommandW();
        if (builtin.os.tag == .windows) {
            // Conduit's default theme is dark; `setTitleBarDark` follows a light theme.
            if (!windows_window.setDarkTitleBar(handle, true)) log.info("windows: DWM refused the dark title bar", .{});
            windows_window.logDpi(handle);
            windows_window.releaseOwnConsole();
        }

        const context = sdl.SDL_GL_CreateContext(handle) orelse {
            var buffer: [256]u8 = undefined;
            log.err("SDL_GL_CreateContext failed: {s}", .{lastError(&buffer)});
            return error.ContextCreationFailed;
        };
        errdefer _ = sdl.SDL_GL_DestroyContext(context);

        // A terminal draws when it has something new to draw, so the swap is left unsynchronised:
        // a blocking vsync would put the loop's latency at the mercy of the compositor for no
        // benefit when there is no frame to pace.
        _ = sdl.SDL_GL_SetSwapInterval(0);

        var window = Window{
            .handle = handle,
            .context = context,
            .id = sdl.SDL_GetWindowID(handle),
            .state = State.init(options.logical, selectScale(options.fixed_scale, Scale.default_factor)),
            .fixed_scale = options.fixed_scale,
            .owns_video = true,
            .driver_events = driver_events,
            .text_input = false,
            .text_area = null,
        };
        const state = window.refresh();
        log.info("window {s}: id {d}, {d}x{d} logical, scale {d:.2}, surface {d}x{d}, {s}{s}", .{
            options.title,
            window.id,
            state.logical.width,
            state.logical.height,
            state.scale.factor,
            state.surface.width_px,
            state.surface.height_px,
            if (options.hidden) "hidden" else "visible",
            if (options.resizable) ", resizable" else "",
        });
        return window;
    }

    /// Give the context, the window and SDL's video subsystem back, in that order: the context
    /// belongs to the window, and SDL belongs to the last window standing.
    pub fn deinit(self: *Window) void {
        if (self.context) |context| {
            _ = sdl.SDL_GL_DestroyContext(context);
            self.context = null;
        }
        if (self.handle) |handle| {
            sdl.SDL_DestroyWindow(handle);
            self.handle = null;
        }
        if (self.owns_video) {
            sdl.SDL_Quit();
            self.owns_video = false;
        }
    }

    /// Choose which macOS Option keys are Alt (the `macos.option_as_alt` setting, TASK-48).
    ///
    /// Two halves of one decision: SDL is told through `SDL_HINT_MAC_OPTION_AS_ALT` so the text
    /// it sends for an Alt-side Option is the plain character instead of the composed one, and
    /// the window remembers the choice so every later key event says whether Option composed
    /// (`KeyEvent.option_composes`). Applies to the next key event; safe to call at any time on
    /// the main thread. The hint is macOS-only; elsewhere this only records the value.
    pub fn setOptionAsAlt(self: *Window, mode: OptionAsAlt) void {
        if (builtin.os.tag == .macos) {
            if (!sdl.SDL_SetHintWithPriority(sdl.SDL_HINT_MAC_OPTION_AS_ALT, mode.sdlHint(), sdl.SDL_HINT_OVERRIDE)) {
                log.warn("SDL refused the Option-as-Alt hint ({s})", .{mode.sdlHint()});
            }
        }
        if (self.option_as_alt != mode) log.info("macOS Option as Alt: {s}", .{@tagName(mode)});
        self.option_as_alt = mode;
    }

    /// Draw the window's title bar dark or light to match the theme (TASK-49). Windows only: DWM's
    /// `DWMWA_USE_IMMERSIVE_DARK_MODE` on the window's HWND; elsewhere the window manager decides
    /// and this does nothing. Cosmetic, so a refusal is logged and ignored. Main thread only.
    pub fn setTitleBarDark(self: *const Window, dark: bool) void {
        if (builtin.os.tag != .windows) return;
        if (!windows_window.setDarkTitleBar(self.handle.?, dark)) {
            log.info("windows: DWM refused the {s} title bar", .{if (dark) "dark" else "light"});
        }
    }

    /// The Option-as-Alt choice in force.
    pub fn optionAsAlt(self: *const Window) OptionAsAlt {
        return self.option_as_alt;
    }

    /// Enter or leave fullscreen. On macOS this is the native fullscreen space (the green button
    /// and Control+Command+F in SDL's Window menu do the same); elsewhere SDL's desktop
    /// fullscreen. The change arrives as an ordinary resize event. Main thread only.
    pub fn setFullscreen(self: *const Window, fullscreen: bool) !void {
        if (!sdl.SDL_SetWindowFullscreen(self.handle.?, fullscreen)) {
            var buffer: [256]u8 = undefined;
            log.warn("SDL_SetWindowFullscreen({}) failed: {s}", .{ fullscreen, lastError(&buffer) });
            return error.FullscreenRefused;
        }
    }

    /// Whether the window is fullscreen right now.
    pub fn isFullscreen(self: *const Window) bool {
        return sdl.SDL_GetWindowFlags(self.handle.?) & sdl.SDL_WINDOW_FULLSCREEN != 0;
    }

    /// Ask the OS what the window looks like right now, and remember the answer.
    ///
    /// This is where an OS-reported scale enters Conduit, and the only place: `selectScale`
    /// either preserves the explicit fixed scale or normalises the report, then `State.init`
    /// turns it into the surface through the one scale rule. A window whose size SDL will not
    /// report keeps the size it last knew, because a stale size is better than a zero one.
    pub fn refresh(self: *Window) State {
        const logical = self.queryLogicalSize() orelse self.state.logical;
        const scale = selectScale(
            self.fixed_scale,
            sdl.SDL_GetWindowDisplayScale(self.handle.?),
        );
        self.state = State.init(logical, scale);
        return self.state;
    }

    /// The window's logical size as the OS reports it.
    pub fn logicalSize(self: *const Window) ?LogicalSize {
        return self.queryLogicalSize();
    }

    /// The drawable size the GL context actually has, as the driver reports it.
    ///
    /// Conduit draws at `state.surface`, which the scale rule derives. This is the other number,
    /// and it exists so the two can be compared: a driver whose pixel size disagrees with the rule
    /// shows up in the log as a mismatch instead of as an image nobody can explain.
    pub fn pixelSize(self: *const Window) ?SurfaceSize {
        var width: c_int = 0;
        var height: c_int = 0;
        if (!sdl.SDL_GetWindowSizeInPixels(self.handle.?, &width, &height)) return null;
        return SurfaceSize.init(@intCast(@max(width, 0)), @intCast(@max(height, 0)));
    }

    /// Capture the backend, density request and actual logical/pixel geometry of this live window.
    ///
    /// This is read-only and must run on the main thread, matching SDL's window-query contract.
    pub fn runtimeInfo(self: *const Window) WindowRuntimeInfo {
        const flags = sdl.SDL_GetWindowFlags(self.handle.?);
        return .{
            .video_backend = videoDriverName(),
            .high_pixel_density = flags & sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY != 0,
            .pixel_density = reportedPixelDensity(sdl.SDL_GetWindowPixelDensity(self.handle.?)),
            .logical_size = self.logicalSize(),
            .pixel_size = self.pixelSize(),
        };
    }

    fn queryLogicalSize(self: *const Window) ?LogicalSize {
        var width: c_int = 0;
        var height: c_int = 0;
        if (!sdl.SDL_GetWindowSize(self.handle.?, &width, &height)) return null;
        return .{
            .width = @intCast(@max(width, 0)),
            .height = @intCast(@max(height, 0)),
        };
    }

    /// Whether the window has keyboard focus right now (TASK-56 raises OS notifications only
    /// while it does not). Main thread only, like every SDL window query.
    pub fn hasInputFocus(self: *const Window) bool {
        const flags = sdl.SDL_GetWindowFlags(self.handle.?);
        return flags & sdl.SDL_WINDOW_INPUT_FOCUS != 0;
    }

    /// Whether the window is on screen: shown and not minimised.
    ///
    /// `render.present` blits to the default framebuffer only for a visible window, so this is what
    /// decides whether the on-screen path runs at all. A hidden window still has a real GL context
    /// and a real surface; its pixels are read from the FBO instead.
    pub fn isVisible(self: *const Window) bool {
        const flags = sdl.SDL_GetWindowFlags(self.handle.?);
        const hidden = flags & sdl.SDL_WINDOW_HIDDEN != 0;
        const minimised = flags & sdl.SDL_WINDOW_MINIMIZED != 0;
        return !hidden and !minimised;
    }

    /// Wait up to `timeout_ms` milliseconds for one event and translate it.
    ///
    /// A negative timeout blocks until an event arrives. `null` means the wait expired with nothing
    /// to report, which is what keeps an idle window free: the thread is asleep inside SDL rather
    /// than spinning over an empty queue.
    pub fn pump(self: *Window, timeout_ms: i32) ?Event {
        var raw: sdl.SDL_Event = undefined;
        if (!sdl.SDL_WaitEventTimeout(&raw, timeout_ms)) return null;
        // A geometry event carries no payload Conduit can trust — SDL puts the logical size on the
        // resize event and the pixel size on the pixel-size event, and a scale change carries
        // nothing at all — so the window asks the OS before translating. Every other event is
        // translated against the state already known.
        const now = if (changesGeometry(eventType(raw))) self.refresh() else self.state;
        const event = translateWithDriverEvents(raw, self.id, self.state, now, self.driver_events, self.option_as_alt) orelse return null;
        self.state = now;
        return event;
    }

    /// Ask the OS to resize the window.
    ///
    /// The request returns once it has been made, not once the window is the new size: the result
    /// arrives as a `resized` event like any other resize, through the same queue a window manager
    /// or a user writes to. That is how the headless driver resizes a window without a user.
    pub fn setLogicalSize(self: *const Window, logical: LogicalSize) !void {
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_SetWindowSize(
            self.handle.?,
            @as(c_int, @intCast(logical.width)),
            @as(c_int, @intCast(logical.height)),
        )) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_SetWindowSize({d}x{d}) failed: {s}", .{
                logical.width,
                logical.height,
                lastError(&buffer),
            });
            return error.ResizeFailed;
        }
    }

    /// Hand the finished default framebuffer to the window system.
    pub fn swap(self: *const Window) void {
        if (!sdl.SDL_GL_SwapWindow(self.handle.?)) {
            var buffer: [256]u8 = undefined;
            log.warn("SDL_GL_SwapWindow failed: {s}", .{lastError(&buffer)});
        }
    }

    /// Post a close request for this window into SDL's queue, as a window manager's close button
    /// does. See `post` for why an app is allowed to do this.
    pub fn postCloseRequest(self: *const Window) !void {
        return self.post(@intCast(sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED));
    }

    /// Post a display-scale-changed notification for this window into SDL's queue, as a display
    /// settings daemon does. See `post` for why an app is allowed to do this.
    pub fn postDisplayScaleChanged(self: *const Window) !void {
        return self.post(@intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED));
    }

    /// Post a scroll wheel event for this window into SDL's queue, as a wheel does. See `post` for
    /// why an app is allowed to do this.
    ///
    /// The payload is filled in the way SDL itself fills one in, so the event the app then reads is
    /// the event a real device would have produced: a headless run has no wheel, and `--scroll-test`
    /// has to prove that scrolling reaches the viewport and the pixels rather than proving that a
    /// function call returns the right number.
    pub fn postWheel(self: *const Window, wheel: Wheel) !void {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.wheel.type = @intCast(sdl.SDL_EVENT_MOUSE_WHEEL);
        raw.wheel.windowID = self.id;
        raw.wheel.x = wheel.dx;
        raw.wheel.y = wheel.dy;
        raw.wheel.mouse_x = wheel.x;
        raw.wheel.mouse_y = wheel.y;
        raw.wheel.direction = if (wheel.flipped)
            sdl.SDL_MOUSEWHEEL_FLIPPED
        else
            sdl.SDL_MOUSEWHEEL_NORMAL;
        raw.wheel.timestamp = sdl.SDL_GetTicksNS();
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_PushEvent(&raw)) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_PushEvent({d}) failed: {s}", .{ @as(c_int, sdl.SDL_EVENT_MOUSE_WHEEL), lastError(&buffer) });
            return error.EventPostFailed;
        }
    }

    /// Post a pointer button event for this window into SDL's queue, as a mouse
    /// does. See `post` for why an app is allowed to do this.
    ///
    /// `mods` is imposed on SDL's keyboard state before the event is queued,
    /// because SDL 3.2 removed the modifier field from its own button events
    /// and the translation reads the state a real key press would have set.
    /// That makes a posted Shift+click indistinguishable from a typed one to
    /// everything above `platform`, which is what `--mouse-test` needs in order
    /// to prove the Shift override the way a person's hand proves it.
    ///
    /// SDL's modifier state is global, so the caller owns restoring it. Nothing
    /// else in Conduit reads it except this translation.
    pub fn postPointerButton(self: *const Window, event: PointerButton) !void {
        sdl.SDL_SetModState(modsToSdl(event.mods));
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.button.type = @intCast(if (event.action == .press)
            sdl.SDL_EVENT_MOUSE_BUTTON_DOWN
        else
            sdl.SDL_EVENT_MOUSE_BUTTON_UP);
        raw.button.windowID = self.id;
        raw.button.button = switch (event.button) {
            .left => sdl.SDL_BUTTON_LEFT,
            .middle => sdl.SDL_BUTTON_MIDDLE,
            .right => sdl.SDL_BUTTON_RIGHT,
        };
        raw.button.down = event.action == .press;
        raw.button.x = event.x;
        raw.button.y = event.y;
        raw.button.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, @intCast(raw.button.type));
    }

    /// Post a pointer motion event for this window into SDL's queue, as a mouse
    /// does. See `post` and `postPointerButton`.
    ///
    /// `state` is the button mask SDL reports alongside motion, filled in here
    /// so the translation's `buttons` answers what a real event would.
    pub fn postPointerMotion(self: *const Window, event: PointerMotion) !void {
        sdl.SDL_SetModState(modsToSdl(event.mods));
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.motion.type = @intCast(sdl.SDL_EVENT_MOUSE_MOTION);
        raw.motion.windowID = self.id;
        raw.motion.state = (if (event.buttons.left) sdl.SDL_BUTTON_LMASK else 0) |
            (if (event.buttons.middle) sdl.SDL_BUTTON_MMASK else 0) |
            (if (event.buttons.right) sdl.SDL_BUTTON_RMASK else 0);
        raw.motion.x = event.x;
        raw.motion.y = event.y;
        raw.motion.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, @intCast(raw.motion.type));
    }

    /// Post a key press or release of a character key for this window into SDL's queue, as a
    /// keyboard does. See `post` for why an app is allowed to do this.
    ///
    /// The scancode is the one the active layout puts `codepoint` on, so the translation's
    /// lookups answer what a real key would; `mods` is carried on the event itself, which is
    /// where SDL reports a key's modifiers. A character the layout only reaches with a shift
    /// level held (`A`, `+`) gets that level added, because the translation derives the
    /// character from the scancode and the level, as it must for a real key, and a hand cannot
    /// type `+` on a US layout without Shift either. `--clipboard-test` needs this to prove the
    /// copy and paste chords and Ctrl+C the way a hand presses them.
    pub fn postCharacterKey(self: *const Window, codepoint: u21, mods: Mods, action: KeyAction) !void {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.key.type = @intCast(if (action == .release) sdl.SDL_EVENT_KEY_UP else sdl.SDL_EVENT_KEY_DOWN);
        raw.key.windowID = self.id;
        var needed: sdl.SDL_Keymod = 0;
        raw.key.scancode = sdl.SDL_GetScancodeFromKey(codepoint, &needed);
        raw.key.mod = modsToSdl(mods) | (needed & level_mods);
        // SDL 3.4 reports a key event's unmodified keycode, so this does too.
        raw.key.key = sdl.SDL_GetKeyFromScancode(raw.key.scancode, raw.key.mod, true);
        raw.key.down = action != .release;
        raw.key.repeat = action == .repeat;
        raw.key.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, @intCast(raw.key.type));
    }

    /// Post a named key into SDL's queue as if the keyboard produced it.
    ///
    /// Named keys use SDL's layout-independent scancode and let SDL derive the matching keycode,
    /// which keeps this path indistinguishable from a real key event after translation.
    pub fn postNamedKey(self: *const Window, key: Key, mods: Mods, action: KeyAction) !void {
        const scancode = scancodeFromKey(key);
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.key.type = @intCast(if (action == .release) sdl.SDL_EVENT_KEY_UP else sdl.SDL_EVENT_KEY_DOWN);
        raw.key.windowID = self.id;
        raw.key.scancode = scancode;
        raw.key.mod = modsToSdl(mods);
        raw.key.key = sdl.SDL_GetKeyFromScancode(scancode, raw.key.mod, true);
        raw.key.down = action != .release;
        raw.key.repeat = action == .repeat;
        raw.key.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, @intCast(raw.key.type));
    }

    /// Wake the main thread because the local driver transport has work ready.
    ///
    /// `SDL_PushEvent` is thread-safe. Posting this on the transport worker uses the same FIFO as
    /// posted key, text and pointer input, so the wake can never overtake earlier input.
    pub fn postDriverWake(self: *const Window) !void {
        return self.postDriverEvent(self.driver_events.wake, 0);
    }

    /// Put a labelled FIFO barrier behind every event posted before this call.
    pub fn postDriverBarrier(self: *const Window, token: u32) !void {
        return self.postDriverEvent(self.driver_events.barrier, token);
    }

    fn postDriverEvent(self: *const Window, kind: SdlEventType, token: u32) !void {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.user.type = kind;
        raw.user.windowID = self.id;
        raw.user.code = @bitCast(token);
        raw.user.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, kind);
    }

    /// Post an in-progress input-method composition for this window into SDL's queue.
    ///
    /// SDL's event borrows `text.ptr`; the caller must keep the sentinel-terminated text alive
    /// until the event has been pumped. This seam deliberately does not allocate or take
    /// ownership, matching the lifetime of text carried by SDL's real input-method events.
    pub fn postTextEditing(self: *const Window, text: [:0]const u8, start: u32, length: u32) !void {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.edit.type = @intCast(sdl.SDL_EVENT_TEXT_EDITING);
        raw.edit.windowID = self.id;
        raw.edit.text = text.ptr;
        raw.edit.start = @intCast(start);
        raw.edit.length = @intCast(length);
        raw.edit.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, @intCast(raw.edit.type));
    }

    /// Post text committed by a keyboard or input method for this window into SDL's queue.
    ///
    /// SDL's event borrows `text.ptr`; the caller must keep the sentinel-terminated text alive
    /// until the event has been pumped. This seam deliberately does not allocate or take
    /// ownership, matching the lifetime of text carried by SDL's real text-input events.
    pub fn postTextInput(self: *const Window, text: [:0]const u8) !void {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.text.type = @intCast(sdl.SDL_EVENT_TEXT_INPUT);
        raw.text.windowID = self.id;
        raw.text.text = text.ptr;
        raw.text.timestamp = sdl.SDL_GetTicksNS();
        try pushRaw(&raw, @intCast(raw.text.type));
    }

    /// Queue one raw pointer-shaped event, reporting the type in any failure.
    ///
    /// By pointer rather than by value: `SDL_PushEvent` takes a mutable pointer
    /// to the event it queues, and a by-value parameter would make that
    /// pointer const. Nothing in Conduit writes through it, but the signature
    /// SDL exposes is the one that has to compile.
    fn pushRaw(raw: *sdl.SDL_Event, kind: SdlEventType) !void {
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_PushEvent(raw)) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_PushEvent({d}) failed: {s}", .{ @as(c_int, @intCast(kind)), lastError(&buffer) });
            return error.EventPostFailed;
        }
    }

    /// Put an SDL event of Conduit's choosing into SDL's own queue.
    ///
    /// It is the same queue a window manager, a compositor or a settings daemon writes to, so the
    /// app's handling path is the real one; only the writer is the app instead of the OS. A
    /// headless run has no user to click the close button and no settings daemon to move the
    /// display, and `--self-test` and the test driver need to drive the app the way a user does.
    ///
    /// The payload is whatever SDL itself sends for the event: a close request and a scale change
    /// both carry only a window id, because the app is expected to re-ask the OS what it now says.
    fn post(self: *const Window, kind: SdlEventType) !void {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.window.type = @intCast(kind);
        raw.window.windowID = self.id;
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_PushEvent(&raw)) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_PushEvent({d}) failed: {s}", .{ kind, lastError(&buffer) });
            return error.EventPostFailed;
        }
    }

    /// Ask the OS to deliver text input for this window, including text composed by an input
    /// method.
    ///
    /// Text input is off until something asks for it, because an OS with an input method attached
    /// will otherwise pop its candidate window up over whatever has focus. A terminal asks for it
    /// once the focused session has a cursor to point at.
    pub fn startTextInput(self: *Window) !void {
        if (self.text_input) return;
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_StartTextInput(self.handle.?)) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_StartTextInput failed: {s}", .{lastError(&buffer)});
            return error.TextInputUnavailable;
        }
        self.text_input = true;
    }

    /// Stop text input, and hide any candidate window the OS had open.
    pub fn stopTextInput(self: *Window) !void {
        if (!self.text_input) return;
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_StopTextInput(self.handle.?)) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_StopTextInput failed: {s}", .{lastError(&buffer)});
            return error.TextInputUnavailable;
        }
        self.text_input = false;
        // The area is forgotten with the input: SDL drops it when text input stops, so keeping the
        // cached copy would mean the next start never re-asserted it and an input method would
        // place its candidate window at a rectangle the OS had forgotten.
        self.text_area = null;
    }

    /// Whether Conduit has text input turned on for this window.
    pub fn textInputActive(self: *const Window) bool {
        return self.text_input;
    }

    /// Tell the OS where this window's text is, so an input method can put its candidate window
    /// beside it rather than in the middle of the screen.
    ///
    /// This is called again whenever the cursor moves, and it is idempotent: an area that has not
    /// changed is not sent to the OS at all, because this is per-frame work otherwise. Nothing here
    /// remembers the cursor for the caller — the OS does not follow it — so a caller that moves the
    /// cursor and does not call this is the reason a candidate window ends up in the wrong place.
    pub fn setTextInputArea(self: *Window, area: TextArea) !void {
        if (self.text_area) |known| {
            if (known.rect.x == area.rect.x and
                known.rect.y == area.rect.y and
                known.rect.width == area.rect.width and
                known.rect.height == area.rect.height and
                known.cursor == area.cursor) return;
        }

        var rect = sdl.SDL_Rect{
            .x = area.rect.x,
            .y = area.rect.y,
            .w = area.rect.width,
            .h = area.rect.height,
        };
        _ = sdl.SDL_ClearError();
        if (!sdl.SDL_SetTextInputArea(self.handle.?, &rect, @intCast(area.cursor))) {
            var buffer: [256]u8 = undefined;
            log.err("SDL_SetTextInputArea({d},{d} {d}x{d} cursor {d}) failed: {s}", .{
                area.rect.x,
                area.rect.y,
                area.rect.width,
                area.rect.height,
                area.cursor,
                lastError(&buffer),
            });
            return error.TextInputUnavailable;
        }
        self.text_area = area;
    }

    /// Where the OS currently thinks this window's text is, as it reports it.
    ///
    /// Read back rather than returned from the cache, because the point of asking is to see what
    /// the OS holds: an area Conduit believes in and the OS disagrees about is the failure this
    /// makes visible.
    pub fn textInputArea(self: *const Window) ?TextArea {
        var rect: sdl.SDL_Rect = undefined;
        var cursor: c_int = 0;
        if (!sdl.SDL_GetTextInputArea(self.handle.?, &rect, &cursor)) return null;
        return .{
            .rect = .{ .x = rect.x, .y = rect.y, .width = rect.w, .height = rect.h },
            .cursor = if (cursor < 0) 0 else @intCast(cursor),
        };
    }

    /// Point the OS's text input at the cell the terminal's cursor is in.
    ///
    /// The one place a cell becomes a rectangle for the OS: `LogicalRect.forCell` is the same rule
    /// the renderer uses to draw the cell, so the input method's candidate window follows the cursor
    /// without a second calculation that could disagree with the first.
    pub fn pointTextInputAt(
        self: *Window,
        column: u32,
        row: u32,
        cell: LogicalSize,
        cursor_bytes: u32,
    ) !void {
        return self.setTextInputArea(.{
            .rect = LogicalRect.forCell(column, row, cell, cursor_bytes),
            .cursor = cursor_bytes,
        });
    }

    /// Host another application's top-level window over `rect` (device pixels in this window),
    /// for the editor pane (TASK-79, decision-12). Only an X11 session can do this; Wayland,
    /// macOS and Windows answer `error.Unsupported`, and the app keeps the editor as a separate
    /// window. `error.NotFound` means nothing matched yet: ask again after the next frame.
    pub fn embedForeignWindow(self: *const Window, match: ForeignWindowMatch, rect: PixelRect) EmbedError!EmbeddedWindow {
        if (!embedSupported(videoDriverName())) return error.Unsupported;
        const handle = self.handle orelse return error.Failed;
        const properties = sdl.SDL_GetWindowProperties(handle);
        if (properties == 0) return error.Failed;
        const parent = sdl.SDL_GetNumberProperty(properties, "SDL.window.x11.window", 0);
        if (parent <= 0) return error.Unsupported;
        return embedIntoX11(@intCast(parent), match, rect);
    }

    /// Move and resize a hosted window to the pane's new rectangle (resize, divider drag, zoom,
    /// sidebar changes).
    pub fn moveEmbedded(_: *const Window, embedded: *EmbeddedWindow, rect: PixelRect) EmbedError!void {
        return moveEmbeddedX11(embedded, rect);
    }

    /// Show or hide a hosted window, for a pane that is not presented (another tab, a zoomed
    /// sibling, a modal over it). Hiding never closes it.
    pub fn showEmbedded(_: *const Window, embedded: *EmbeddedWindow, visible: bool) EmbedError!void {
        return showEmbeddedX11(embedded, visible);
    }

    /// Ask a hosted window to close itself (`WM_DELETE_WINDOW`), as its own close button would.
    pub fn closeEmbedded(_: *const Window, embedded: *EmbeddedWindow) EmbedError!void {
        return requestCloseX11(embedded);
    }

    /// Stop hosting: give a still-running client back to the desktop and release everything.
    pub fn unembed(_: *const Window, embedded: *EmbeddedWindow) void {
        unembedX11(embedded);
    }
};

// ---------------------------------------------------------------------------
// Hosting a foreign window over a pane (TASK-79, decision-12)
// ---------------------------------------------------------------------------

/// Why another application's window could not be hosted, moved or released.
pub const EmbedError = error{
    /// This windowing system cannot host another client's window (Wayland), or hosting is not
    /// implemented here yet (macOS, Windows). The app shows the editor as a separate window.
    Unsupported,
    /// No top-level window matched yet; an application that was just launched may still be
    /// mapping it, so the caller asks again later.
    NotFound,
    /// The display connection or a window request failed, or the window vanished.
    Failed,
};

/// Which top-level window to host. Every field that is set must match; at least one must be.
pub const ForeignWindowMatch = struct {
    /// The client's `_NET_WM_PID`.
    pid: ?u32 = null,
    /// The client's `WM_CLASS` class or instance name, compared ignoring ASCII case.
    class: ?[]const u8 = null,
    /// Text the client's title (`_NET_WM_NAME`, else `WM_NAME`) contains.
    title_contains: ?[]const u8 = null,

    fn isEmpty(self: ForeignWindowMatch) bool {
        return self.pid == null and self.class == null and self.title_contains == null;
    }
};

/// A rectangle in the window's device pixels, origin top left: where a hosted window sits.
pub const PixelRect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// Whether hosting can work under the named SDL video driver on this build. Only X11 can
/// reparent another client's window; Xlib is loaded at run time, which needs the C library's
/// `dlopen`.
pub fn embedSupported(video_driver: ?[]const u8) bool {
    if (comptime !x11_embedding_built) return false;
    const name = video_driver orelse return false;
    return std.mem.eql(u8, name, "x11");
}

const x11_embedding_built = builtin.os.tag == .linux and builtin.link_libc;

/// A foreign window hosted inside Conduit's window: Conduit's own child "container" window at
/// the pane's rectangle, with the client reparented into it.
///
/// Owns a private display connection, so hosting never touches SDL's own. Owner (UI) thread
/// only. Release with `Window.unembed`, which gives the client back to the root window when it
/// still exists. Never copy a live value.
pub const EmbeddedWindow = struct {
    display: *anyopaque,
    container: c_ulong,
    client: c_ulong,
    /// The client's `_NET_WM_PID`, when it set one.
    pid: ?u32,
    visible: bool = true,
};

/// The Xlib entry points hosting uses, resolved once from `libX11.so.6` at run time so Conduit
/// has no link-time X11 dependency and still starts where libX11 is absent (SDL loads X11 the
/// same way). The library stays loaded for the life of the process, as SDL's does.
const X11 = struct {
    const Display = anyopaque;
    const XID = c_ulong;
    const Atom = c_ulong;
    const ErrorHandler = ?*const fn (?*Display, ?*anyopaque) callconv(.c) c_int;

    const ClassHint = extern struct {
        res_name: ?[*:0]u8 = null,
        res_class: ?[*:0]u8 = null,
    };

    const ClientMessageEvent = extern struct {
        type: c_int,
        serial: c_ulong = 0,
        send_event: c_int = 1,
        display: ?*Display,
        window: XID,
        message_type: Atom,
        format: c_int,
        data: [5]c_long,
    };

    /// Xlib's `XEvent` is a union padded to 24 longs.
    const XEvent = extern union {
        client: ClientMessageEvent,
        pad: [24]c_long,
    };

    const client_message: c_int = 33;
    const xa_cardinal: Atom = 6;
    const any_property_type: Atom = 0;
    const success: c_int = 0;

    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (*Display) callconv(.c) XID,
    XQueryTree: *const fn (*Display, XID, *XID, *XID, *?[*]XID, *c_uint) callconv(.c) c_int,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
    XGetClassHint: *const fn (*Display, XID, *ClassHint) callconv(.c) c_int,
    XFetchName: *const fn (*Display, XID, *?[*:0]u8) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    XGetWindowProperty: *const fn (*Display, XID, Atom, c_long, c_long, c_int, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *?[*]u8) callconv(.c) c_int,
    XCreateSimpleWindow: *const fn (*Display, XID, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) XID,
    XDestroyWindow: *const fn (*Display, XID) callconv(.c) c_int,
    XMapWindow: *const fn (*Display, XID) callconv(.c) c_int,
    XUnmapWindow: *const fn (*Display, XID) callconv(.c) c_int,
    XReparentWindow: *const fn (*Display, XID, XID, c_int, c_int) callconv(.c) c_int,
    XMoveResizeWindow: *const fn (*Display, XID, c_int, c_int, c_uint, c_uint) callconv(.c) c_int,
    XResizeWindow: *const fn (*Display, XID, c_uint, c_uint) callconv(.c) c_int,
    XSendEvent: *const fn (*Display, XID, c_int, c_long, *XEvent) callconv(.c) c_int,
    XSync: *const fn (*Display, c_int) callconv(.c) c_int,
    XSetErrorHandler: *const fn (ErrorHandler) callconv(.c) ErrorHandler,

    var loaded: ?X11 = null;
    var load_failed = false;
    var lib: ?std.DynLib = null;
    /// Set by `recordError` while a guarded request batch runs. Owner thread only.
    var error_seen = false;

    /// The resolved entry points, or null when libX11 or one of its symbols is missing.
    fn get() ?*const X11 {
        if (comptime !x11_embedding_built) return null;
        if (loaded != null) return &loaded.?;
        if (load_failed) return null;
        lib = std.DynLib.open("libX11.so.6") catch {
            load_failed = true;
            return null;
        };
        var api: X11 = undefined;
        inline for (@typeInfo(X11).@"struct".fields) |field| {
            @field(api, field.name) = lib.?.lookup(field.type, field.name ++ "") orelse {
                load_failed = true;
                return null;
            };
        }
        loaded = api;
        return &loaded.?;
    }

    fn recordError(_: ?*Display, _: ?*anyopaque) callconv(.c) c_int {
        error_seen = true;
        return 0;
    }

    /// Run a batch of requests with Xlib's process-wide error handler replaced, so a client that
    /// vanished mid-batch is an error value instead of Xlib's default exit. SDL installs its own
    /// handler; it is restored after the batch has been synced, so no error of ours reaches it.
    fn guarded(self: *const X11, display: *Display) Guard {
        error_seen = false;
        return .{ .api = self, .display = display, .previous = self.XSetErrorHandler(recordError) };
    }

    const Guard = struct {
        api: *const X11,
        display: *Display,
        previous: ErrorHandler,

        /// Sync, restore the previous handler and report whether any request failed.
        fn finish(self: Guard) bool {
            _ = self.api.XSync(self.display, 0);
            _ = self.api.XSetErrorHandler(self.previous);
            return !error_seen;
        }
    };

    fn propertyCardinal(self: *const X11, display: *Display, window: XID, atom: Atom) ?u32 {
        var actual_type: Atom = 0;
        var format: c_int = 0;
        var items: c_ulong = 0;
        var after: c_ulong = 0;
        var data: ?[*]u8 = null;
        if (self.XGetWindowProperty(display, window, atom, 0, 1, 0, xa_cardinal, &actual_type, &format, &items, &after, &data) != success) return null;
        defer if (data) |bytes| {
            _ = self.XFree(bytes);
        };
        if (actual_type != xa_cardinal or format != 32 or items < 1) return null;
        // Format-32 items arrive as C longs whatever the server's word size.
        const longs: [*]align(1) const c_long = @ptrCast(data orelse return null);
        const value = longs[0];
        if (value <= 0 or value > std.math.maxInt(u32)) return null;
        return @intCast(value);
    }

    fn titleContains(self: *const X11, display: *Display, window: XID, needle: []const u8) bool {
        const net_wm_name = self.XInternAtom(display, "_NET_WM_NAME", 1);
        if (net_wm_name != 0) {
            var actual_type: Atom = 0;
            var format: c_int = 0;
            var items: c_ulong = 0;
            var after: c_ulong = 0;
            var data: ?[*]u8 = null;
            if (self.XGetWindowProperty(display, window, net_wm_name, 0, 1024, 0, any_property_type, &actual_type, &format, &items, &after, &data) == success) {
                defer if (data) |bytes| {
                    _ = self.XFree(bytes);
                };
                if (data) |bytes| if (format == 8 and items != 0) {
                    if (std.mem.indexOf(u8, bytes[0..@intCast(items)], needle) != null) return true;
                };
            }
        }
        var name: ?[*:0]u8 = null;
        if (self.XFetchName(display, window, &name) == 0) return false;
        defer if (name) |text| {
            _ = self.XFree(text);
        };
        const text = std.mem.span(name orelse return false);
        return std.mem.indexOf(u8, text, needle) != null;
    }

    fn classMatches(self: *const X11, display: *Display, window: XID, class: []const u8) bool {
        var hint: ClassHint = .{};
        if (self.XGetClassHint(display, window, &hint) == 0) return false;
        defer {
            if (hint.res_name) |text| _ = self.XFree(text);
            if (hint.res_class) |text| _ = self.XFree(text);
        }
        if (hint.res_class) |text| if (std.ascii.eqlIgnoreCase(std.mem.span(text), class)) return true;
        if (hint.res_name) |text| if (std.ascii.eqlIgnoreCase(std.mem.span(text), class)) return true;
        return false;
    }

    fn matches(self: *const X11, display: *Display, window: XID, match: ForeignWindowMatch) bool {
        if (match.class) |class| if (!self.classMatches(display, window, class)) return false;
        if (match.title_contains) |needle| if (!self.titleContains(display, window, needle)) return false;
        if (match.pid) |pid| {
            const atom = self.XInternAtom(display, "_NET_WM_PID", 1);
            if (atom == 0 or self.propertyCardinal(display, window, atom) != pid) return false;
        }
        return true;
    }

    /// Search the root's children and two levels below (a window manager's frames hold the
    /// clients) for the first window matching, skipping `exclude`.
    fn find(self: *const X11, display: *Display, root: XID, match: ForeignWindowMatch, exclude: XID) ?XID {
        return self.findBelow(display, root, match, exclude, 3);
    }

    fn findBelow(self: *const X11, display: *Display, parent: XID, match: ForeignWindowMatch, exclude: XID, depth: u8) ?XID {
        if (depth == 0) return null;
        var root_return: XID = 0;
        var parent_return: XID = 0;
        var children: ?[*]XID = null;
        var count: c_uint = 0;
        if (self.XQueryTree(display, parent, &root_return, &parent_return, &children, &count) == 0) return null;
        defer if (children) |list| {
            _ = self.XFree(list);
        };
        const list = (children orelse return null)[0..count];
        for (list) |child| {
            if (child != exclude and self.matches(display, child, match)) return child;
        }
        for (list) |child| {
            if (child == exclude) continue;
            if (self.findBelow(display, child, match, exclude, depth - 1)) |found| return found;
        }
        return null;
    }

    fn parentOf(self: *const X11, display: *Display, window: XID) ?XID {
        var root_return: XID = 0;
        var parent_return: XID = 0;
        var children: ?[*]XID = null;
        var count: c_uint = 0;
        if (self.XQueryTree(display, window, &root_return, &parent_return, &children, &count) == 0) return null;
        if (children) |list| _ = self.XFree(list);
        return parent_return;
    }
};

fn clampDimension(value: u32) c_uint {
    return @intCast(@min(@max(value, 1), std.math.maxInt(u16)));
}

fn clampOffset(value: i32) c_int {
    return @intCast(std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16)));
}

/// Host the first top-level window matching `match` inside X11 window `parent` at `rect`: a
/// container child of `parent` is created there, the client is withdrawn, reparented into it,
/// sized to it and mapped. Owner thread.
fn embedIntoX11(parent: c_ulong, match: ForeignWindowMatch, rect: PixelRect) EmbedError!EmbeddedWindow {
    if (match.isEmpty()) return error.NotFound;
    const api = X11.get() orelse return error.Unsupported;
    const display = api.XOpenDisplay(null) orelse return error.Failed;
    errdefer _ = api.XCloseDisplay(display);
    const root = api.XDefaultRootWindow(display);
    const client = api.find(display, root, match, parent) orelse return error.NotFound;
    const pid: ?u32 = pid: {
        const atom = api.XInternAtom(display, "_NET_WM_PID", 1);
        break :pid if (atom == 0) null else api.propertyCardinal(display, client, atom);
    };

    const guard = api.guarded(display);
    const width = clampDimension(rect.width);
    const height = clampDimension(rect.height);
    const container = api.XCreateSimpleWindow(display, parent, clampOffset(rect.x), clampOffset(rect.y), width, height, 0, 0, 0);
    _ = api.XMapWindow(display, container);
    // Unmapping first withdraws a managed client, so the window manager lets go of it before
    // it moves into the container.
    _ = api.XUnmapWindow(display, client);
    _ = api.XReparentWindow(display, client, container, 0, 0);
    _ = api.XResizeWindow(display, client, width, height);
    _ = api.XMapWindow(display, client);
    if (!guard.finish()) {
        const cleanup = api.guarded(display);
        _ = api.XDestroyWindow(display, container);
        _ = cleanup.finish();
        return error.Failed;
    }
    return .{ .display = display, .container = container, .client = client, .pid = pid };
}

fn moveEmbeddedX11(embedded: *EmbeddedWindow, rect: PixelRect) EmbedError!void {
    const api = X11.get() orelse return error.Unsupported;
    const guard = api.guarded(embedded.display);
    const width = clampDimension(rect.width);
    const height = clampDimension(rect.height);
    _ = api.XMoveResizeWindow(embedded.display, embedded.container, clampOffset(rect.x), clampOffset(rect.y), width, height);
    _ = api.XResizeWindow(embedded.display, embedded.client, width, height);
    if (!guard.finish()) return error.Failed;
}

fn showEmbeddedX11(embedded: *EmbeddedWindow, visible: bool) EmbedError!void {
    if (embedded.visible == visible) return;
    const api = X11.get() orelse return error.Unsupported;
    const guard = api.guarded(embedded.display);
    _ = if (visible) api.XMapWindow(embedded.display, embedded.container) else api.XUnmapWindow(embedded.display, embedded.container);
    if (!guard.finish()) return error.Failed;
    embedded.visible = visible;
}

fn requestCloseX11(embedded: *EmbeddedWindow) EmbedError!void {
    const api = X11.get() orelse return error.Unsupported;
    const protocols = api.XInternAtom(embedded.display, "WM_PROTOCOLS", 0);
    const delete = api.XInternAtom(embedded.display, "WM_DELETE_WINDOW", 0);
    var event: X11.XEvent = .{ .client = .{
        .type = X11.client_message,
        .display = embedded.display,
        .window = embedded.client,
        .message_type = protocols,
        .format = 32,
        .data = .{ @intCast(delete), 0, 0, 0, 0 },
    } };
    const guard = api.guarded(embedded.display);
    _ = api.XSendEvent(embedded.display, embedded.client, 0, 0, &event);
    if (!guard.finish()) return error.Failed;
}

/// Give a still-existing client back to the root window, mapped, then destroy the container
/// and close the private connection.
fn unembedX11(embedded: *EmbeddedWindow) void {
    const api = X11.get() orelse return;
    const guard = api.guarded(embedded.display);
    const root = api.XDefaultRootWindow(embedded.display);
    _ = api.XUnmapWindow(embedded.display, embedded.client);
    _ = api.XReparentWindow(embedded.display, embedded.client, root, 0, 0);
    _ = api.XMapWindow(embedded.display, embedded.client);
    _ = api.XDestroyWindow(embedded.display, embedded.container);
    // A client that already exited makes the requests above fail; there is nothing left to
    // give back then, and the container is destroyed either way.
    _ = guard.finish();
    _ = api.XCloseDisplay(embedded.display);
    embedded.* = undefined;
}

// ---------------------------------------------------------------------------
// Local test-driver transport
// ---------------------------------------------------------------------------

/// Largest request payload accepted by the driver transport, excluding its newline.
pub const max_driver_request_bytes: usize = 1024 * 1024;

/// Largest response payload accepted by the driver transport, excluding its newline.
pub const max_driver_response_bytes: usize = 4 * 1024 * 1024;

/// Compatibility name for the original request-frame limit.
pub const max_driver_frame_bytes = max_driver_request_bytes;

/// Maximum number of owned messages waiting on either side of the main/worker handoff.
pub const max_driver_pending: usize = 64;

/// An asynchronous transport failure observed by its worker.
///
/// This deliberately carries no peer bytes: driver input is untrusted and can contain terminal
/// contents or prompts, so even the error channel cannot accidentally become a payload log.
pub const DriverTransportIssue = enum(u8) {
    none,
    accept_failed,
    connection_failed,
    malformed_frame,
    frame_too_large,
    request_queue_full,
    response_token_mismatch,
    wake_failed,
};

/// One newline-delimited driver request, with the delimiter removed.
///
/// Ownership transfers from `DriverTransport.takeRequest` to the caller. Call `deinit` exactly
/// once with the allocator that started the transport.
pub const DriverRequest = struct {
    token: u64,
    bytes: []u8,

    pub fn deinit(self: *DriverRequest, allocator: Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const DriverResponse = struct {
    token: u64,
    bytes: []u8,
};

/// The Win32 named-pipe seam for the local driver transport.
///
/// All declarations stay here so no Windows handle escapes `platform`. The pipe is overlapped so
/// `DriverTransport.stop` can cancel either a pending connect or read before joining its worker.
const WindowsDriver = struct {
    const windows = std.os.windows;
    const HANDLE = windows.HANDLE;
    const BOOL = windows.BOOL;
    const DWORD = windows.DWORD;

    const pipe_prefix = "\\\\.\\pipe\\";
    const max_pipe_path_chars: usize = 256;
    const pipe_buffer_bytes: DWORD = 64 * 1024;

    const pipe_access_duplex: DWORD = 0x00000003;
    const file_flag_first_pipe_instance: DWORD = 0x00080000;
    const file_flag_overlapped: DWORD = 0x40000000;
    const pipe_type_byte: DWORD = 0x00000000;
    const pipe_readmode_byte: DWORD = 0x00000000;
    const pipe_wait: DWORD = 0x00000000;
    const pipe_reject_remote_clients: DWORD = 0x00000008;
    const generic_read: DWORD = 0x80000000;
    const generic_write: DWORD = 0x40000000;
    const open_existing: DWORD = 3;
    const token_query: DWORD = 0x00000008;
    const token_logon_sid: DWORD = 28;
    const token_user: DWORD = 1;
    const pipe_unlimited_instances: DWORD = 255;
    const sddl_revision_1: DWORD = 1;

    const Listener = struct {
        pipe: HANDLE,
        event: HANDLE,
        stop_event: HANDLE,
    };

    const Overlapped = extern struct {
        internal: windows.ULONG_PTR,
        internal_high: windows.ULONG_PTR,
        offset: extern union {
            named: extern struct { offset: DWORD, offset_high: DWORD },
            pointer: ?*anyopaque,
        },
        event: ?HANDLE,
    };

    const SidAndAttributes = extern struct {
        sid: ?*anyopaque,
        attributes: DWORD,
    };

    const TokenGroups = extern struct {
        group_count: DWORD,
        groups: [1]SidAndAttributes,
    };

    const IoError = error{
        Cancelled,
        Disconnected,
        Failed,
    };

    extern "kernel32" fn CreateNamedPipeW(
        name: windows.LPCWSTR,
        open_mode: DWORD,
        pipe_mode: DWORD,
        max_instances: DWORD,
        out_buffer_size: DWORD,
        in_buffer_size: DWORD,
        default_timeout_ms: DWORD,
        attributes: *windows.SECURITY_ATTRIBUTES,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: *Overlapped) callconv(.winapi) BOOL;
    extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateFileW(
        name: windows.LPCWSTR,
        desired_access: DWORD,
        share_mode: DWORD,
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        creation_disposition: DWORD,
        flags_and_attributes: DWORD,
        template: ?HANDLE,
    ) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(
        handle: HANDLE,
        buffer: [*]u8,
        count: DWORD,
        transferred: ?*DWORD,
        overlapped: ?*Overlapped,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(
        handle: HANDLE,
        buffer: [*]const u8,
        count: DWORD,
        transferred: ?*DWORD,
        overlapped: ?*Overlapped,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn GetOverlappedResult(
        handle: HANDLE,
        overlapped: *Overlapped,
        transferred: *DWORD,
        wait: BOOL,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CancelIoEx(handle: HANDLE, overlapped: ?*Overlapped) callconv(.winapi) BOOL;
    extern "kernel32" fn CreateEventW(
        attributes: ?*windows.SECURITY_ATTRIBUTES,
        manual_reset: BOOL,
        initial_state: BOOL,
        name: ?windows.LPCWSTR,
    ) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn ResetEvent(event: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn SetEvent(event: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn WaitForMultipleObjects(
        count: DWORD,
        handles: [*]const HANDLE,
        wait_all: BOOL,
        timeout_ms: DWORD,
    ) callconv(.winapi) DWORD;
    extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitNamedPipeW(name: windows.LPCWSTR, timeout_ms: DWORD) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
    extern "advapi32" fn ImpersonateAnonymousToken(thread: HANDLE) callconv(.winapi) BOOL;
    extern "advapi32" fn RevertToSelf() callconv(.winapi) BOOL;

    extern "advapi32" fn OpenProcessToken(
        process: HANDLE,
        desired_access: DWORD,
        token: *HANDLE,
    ) callconv(.winapi) BOOL;
    extern "advapi32" fn GetTokenInformation(
        token: HANDLE,
        information_class: DWORD,
        information: ?*anyopaque,
        information_bytes: DWORD,
        required_bytes: *DWORD,
    ) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertSidToStringSidW(
        sid: *anyopaque,
        string_sid: *?windows.LPWSTR,
    ) callconv(.winapi) BOOL;
    extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        string_descriptor: windows.LPCWSTR,
        revision: DWORD,
        descriptor: *?*anyopaque,
        descriptor_bytes: ?*DWORD,
    ) callconv(.winapi) BOOL;

    fn buildSddl(allocator: Allocator, sid: []const u8) Allocator.Error![]u8 {
        return std.fmt.allocPrint(allocator, "D:P(A;;GRGW;;;{s})", .{sid});
    }

    fn createSecurityDescriptor(allocator: Allocator) (Allocator.Error || error{WindowsSecurityUnavailable})!*anyopaque {
        var token: HANDLE = windows.INVALID_HANDLE_VALUE;
        if (OpenProcessToken(windows.GetCurrentProcess(), token_query, &token) == .FALSE) {
            return error.WindowsSecurityUnavailable;
        }
        defer windows.CloseHandle(token);

        var information_bytes: DWORD = 0;
        if (GetTokenInformation(token, token_logon_sid, null, 0, &information_bytes) != .FALSE or
            windows.GetLastError() != .INSUFFICIENT_BUFFER or
            information_bytes < @sizeOf(TokenGroups))
        {
            return error.WindowsSecurityUnavailable;
        }
        const information = try allocator.alignedAlloc(u8, .of(TokenGroups), information_bytes);
        defer allocator.free(information);
        if (GetTokenInformation(
            token,
            token_logon_sid,
            @ptrCast(information.ptr),
            information_bytes,
            &information_bytes,
        ) == .FALSE) return error.WindowsSecurityUnavailable;

        const groups: *const TokenGroups = @ptrCast(information.ptr);
        if (groups.group_count != 1) return error.WindowsSecurityUnavailable;
        const sid = groups.groups[0].sid orelse return error.WindowsSecurityUnavailable;

        var sid_wide: ?windows.LPWSTR = null;
        if (ConvertSidToStringSidW(sid, &sid_wide) == .FALSE) return error.WindowsSecurityUnavailable;
        defer _ = LocalFree(@ptrCast(sid_wide.?));

        const sid_text = std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(sid_wide.?)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ExpectedSecondSurrogateHalf, error.DanglingSurrogateHalf, error.UnexpectedSecondSurrogateHalf => return error.WindowsSecurityUnavailable,
        };
        defer allocator.free(sid_text);
        const sddl = try buildSddl(allocator, sid_text);
        defer allocator.free(sddl);
        const sddl_wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, sddl) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidUtf8 => return error.WindowsSecurityUnavailable,
        };
        defer allocator.free(sddl_wide);

        var descriptor: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl_wide.ptr,
            sddl_revision_1,
            &descriptor,
            null,
        ) == .FALSE) return error.WindowsSecurityUnavailable;
        return descriptor orelse error.WindowsSecurityUnavailable;
    }

    fn pipeName(endpoint: []const u8, buffer: *[max_pipe_path_chars + 1]u16) [:0]const u16 {
        for (endpoint, 0..) |byte, index| buffer[index] = byte;
        buffer[endpoint.len] = 0;
        return buffer[0..endpoint.len :0];
    }

    fn createListener(allocator: Allocator, endpoint: []const u8) DriverTransport.StartError!Listener {
        const descriptor = try createSecurityDescriptor(allocator);
        defer _ = LocalFree(descriptor);
        var attributes: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = descriptor,
            .bInheritHandle = .FALSE,
        };
        var name_buffer: [max_pipe_path_chars + 1]u16 = undefined;
        const name = pipeName(endpoint, &name_buffer);
        const pipe = CreateNamedPipeW(
            name.ptr,
            pipe_access_duplex | file_flag_first_pipe_instance | file_flag_overlapped,
            pipe_type_byte | pipe_readmode_byte | pipe_wait | pipe_reject_remote_clients,
            1,
            pipe_buffer_bytes,
            pipe_buffer_bytes,
            0,
            &attributes,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) {
            if (windows.GetLastError() == .ACCESS_DENIED) return error.EndpointOccupied;
            return error.ListenerFailed;
        }
        errdefer windows.CloseHandle(pipe);
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.ListenerFailed;
        errdefer windows.CloseHandle(event);
        const stop_event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.ListenerFailed;
        return .{ .pipe = pipe, .event = event, .stop_event = stop_event };
    }

    /// One more instance of the pipe `name` for a multi-instance listener (the control API): the
    /// first refuses a name another process already holds, exactly like the driver's single
    /// instance; later ones join the pipe the first created, whose descriptor already decides who
    /// may connect. Every instance rejects remote clients. `stop_event` is left null for the
    /// caller to supply.
    fn createInstance(name: [:0]const u16, descriptor: *anyopaque, first: bool) error{ EndpointOccupied, ListenerFailed }!struct { pipe: HANDLE, event: HANDLE } {
        var attributes: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = descriptor,
            .bInheritHandle = .FALSE,
        };
        const pipe = CreateNamedPipeW(
            name.ptr,
            pipe_access_duplex | file_flag_overlapped | (if (first) file_flag_first_pipe_instance else 0),
            pipe_type_byte | pipe_readmode_byte | pipe_wait | pipe_reject_remote_clients,
            pipe_unlimited_instances,
            pipe_buffer_bytes,
            pipe_buffer_bytes,
            0,
            &attributes,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) {
            if (first and windows.GetLastError() == .ACCESS_DENIED) return error.EndpointOccupied;
            return error.ListenerFailed;
        }
        errdefer windows.CloseHandle(pipe);
        const event = CreateEventW(null, .TRUE, .FALSE, null) orelse return error.ListenerFailed;
        return .{ .pipe = pipe, .event = event };
    }

    /// The current user's SID as text (`S-1-5-21-…`) in `buffer`, or null.
    fn currentUserSid(buffer: []u8) ?[]const u8 {
        var token: HANDLE = windows.INVALID_HANDLE_VALUE;
        if (OpenProcessToken(windows.GetCurrentProcess(), token_query, &token) == .FALSE) return null;
        defer windows.CloseHandle(token);
        var information: [256]u8 align(@alignOf(SidAndAttributes)) = undefined;
        var information_bytes: DWORD = 0;
        if (GetTokenInformation(token, token_user, &information, information.len, &information_bytes) == .FALSE) return null;
        const user: *const SidAndAttributes = @ptrCast(&information);
        const sid = user.sid orelse return null;
        var sid_wide: ?windows.LPWSTR = null;
        if (ConvertSidToStringSidW(sid, &sid_wide) == .FALSE) return null;
        defer _ = LocalFree(@ptrCast(sid_wide.?));
        const wide = std.mem.span(sid_wide.?);
        if (wide.len > buffer.len) return null;
        for (wide, 0..) |unit, index| {
            // A SID's text is `S`, digits and dashes; anything else is not one.
            if (unit > 0x7f) return null;
            buffer[index] = @intCast(unit);
        }
        return buffer[0..wide.len];
    }

    fn closeListener(listener: Listener) void {
        windows.CloseHandle(listener.stop_event);
        windows.CloseHandle(listener.event);
        windows.CloseHandle(listener.pipe);
    }

    fn connect(listener: Listener) IoError!void {
        while (true) {
            if (ResetEvent(listener.event) == .FALSE) return error.Failed;
            var overlapped: Overlapped = std.mem.zeroes(Overlapped);
            overlapped.event = listener.event;
            if (ConnectNamedPipe(listener.pipe, &overlapped) != .FALSE) return;
            switch (windows.GetLastError()) {
                .PIPE_CONNECTED => return,
                .NO_DATA => {
                    _ = DisconnectNamedPipe(listener.pipe);
                    continue;
                },
                .IO_PENDING => {
                    var transferred: DWORD = 0;
                    try finishOverlapped(listener, &overlapped, &transferred);
                    return;
                },
                else => return ioFailure(),
            }
        }
    }

    fn disconnect(listener: Listener) void {
        _ = DisconnectNamedPipe(listener.pipe);
    }

    fn cancel(listener: Listener) void {
        _ = SetEvent(listener.stop_event);
        if (CancelIoEx(listener.pipe, null) == .FALSE and windows.GetLastError() != .NOT_FOUND) {
            return;
        }
    }

    fn overlappedRead(listener: Listener, buffer: []u8) IoError!usize {
        if (ResetEvent(listener.event) == .FALSE) return error.Failed;
        var overlapped: Overlapped = std.mem.zeroes(Overlapped);
        overlapped.event = listener.event;
        var transferred: DWORD = 0;
        if (ReadFile(listener.pipe, buffer.ptr, @intCast(buffer.len), &transferred, &overlapped) != .FALSE) {
            return transferred;
        }
        if (windows.GetLastError() != .IO_PENDING) return ioFailure();
        try finishOverlapped(listener, &overlapped, &transferred);
        return transferred;
    }

    fn overlappedWriteAll(listener: Listener, bytes: []const u8) IoError!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (ResetEvent(listener.event) == .FALSE) return error.Failed;
            var overlapped: Overlapped = std.mem.zeroes(Overlapped);
            overlapped.event = listener.event;
            var transferred: DWORD = 0;
            const remaining = bytes[offset..];
            if (WriteFile(listener.pipe, remaining.ptr, @intCast(remaining.len), &transferred, &overlapped) == .FALSE) {
                if (windows.GetLastError() != .IO_PENDING) return ioFailure();
                try finishOverlapped(listener, &overlapped, &transferred);
            }
            if (transferred == 0) return error.Disconnected;
            offset += transferred;
        }
    }

    fn finishOverlapped(listener: Listener, overlapped: *Overlapped, transferred: *DWORD) IoError!void {
        const handles = [_]HANDLE{ listener.event, listener.stop_event };
        switch (WaitForMultipleObjects(@intCast(handles.len), handles[0..].ptr, .FALSE, 0xffffffff)) {
            0 => if (GetOverlappedResult(listener.pipe, overlapped, transferred, .FALSE) == .FALSE) {
                return ioFailure();
            },
            1 => {
                _ = CancelIoEx(listener.pipe, overlapped);
                _ = GetOverlappedResult(listener.pipe, overlapped, transferred, .TRUE);
                return error.Cancelled;
            },
            else => {
                _ = CancelIoEx(listener.pipe, overlapped);
                _ = GetOverlappedResult(listener.pipe, overlapped, transferred, .TRUE);
                return error.Failed;
            },
        }
    }

    fn ioFailure() IoError {
        return switch (windows.GetLastError()) {
            .OPERATION_ABORTED => error.Cancelled,
            .BROKEN_PIPE, .NO_DATA, .PIPE_NOT_CONNECTED => error.Disconnected,
            else => error.Failed,
        };
    }

    fn openClient(endpoint: []const u8) error{ConnectionFailed}!HANDLE {
        var name_buffer: [max_pipe_path_chars + 1]u16 = undefined;
        const name = pipeName(endpoint, &name_buffer);
        const pipe = CreateFileW(
            name.ptr,
            generic_read | generic_write,
            0,
            null,
            open_existing,
            0,
            null,
        );
        if (pipe != windows.INVALID_HANDLE_VALUE) return pipe;
        // Every instance of a multi-instance pipe can be busy for the moment between one
        // client's connection and the server's next instance; wait for one, briefly.
        var attempts: usize = 0;
        while (windows.GetLastError() == .PIPE_BUSY and attempts < 10) : (attempts += 1) {
            if (WaitNamedPipeW(name.ptr, 500) == .FALSE and windows.GetLastError() != .SEM_TIMEOUT) break;
            const retried = CreateFileW(name.ptr, generic_read | generic_write, 0, null, open_existing, 0, null);
            if (retried != windows.INVALID_HANDLE_VALUE) return retried;
        }
        return error.ConnectionFailed;
    }

    fn clientWriteAll(pipe: HANDLE, bytes: []const u8) error{ConnectionFailed}!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            var transferred: DWORD = 0;
            const remaining = bytes[offset..];
            if (WriteFile(pipe, remaining.ptr, @intCast(remaining.len), &transferred, null) == .FALSE or
                transferred == 0)
            {
                return error.ConnectionFailed;
            }
            offset += transferred;
        }
    }

    fn clientRead(pipe: HANDLE, buffer: []u8) error{ ConnectionFailed, EndOfStream }!usize {
        var transferred: DWORD = 0;
        if (ReadFile(pipe, buffer.ptr, @intCast(buffer.len), &transferred, null) == .FALSE) {
            return switch (windows.GetLastError()) {
                .BROKEN_PIPE, .NO_DATA, .PIPE_NOT_CONNECTED => error.EndOfStream,
                else => error.ConnectionFailed,
            };
        }
        if (transferred == 0) return error.EndOfStream;
        return transferred;
    }
};

const DriverListener = if (builtin.os.tag == .windows) WindowsDriver.Listener else std.Io.net.Server;
const DriverConnection = if (builtin.os.tag == .windows) WindowsDriver.HANDLE else std.Io.net.Stream;

/// A bounded, local-only, newline-framed bridge between a driver client and Conduit's main loop.
///
/// Ownership and threading:
/// - `start`, `takeRequest`, `respond`, `takeIssue`, `stop` and `deinit` run on the main thread.
/// - Blocking accept/read/write calls run only on the owned worker thread.
/// - `window` is borrowed and must outlive the transport; the worker uses only the thread-safe
///   `Window.postDriverWake` method.
/// - Requests returned by `takeRequest` are caller-owned. Responses are copied by `respond` and
///   freed by the worker after they are written.
///
/// Linux and macOS use an explicit filesystem AF_UNIX endpoint. Windows accepts only an exact
/// local named-pipe path and creates it with a protected current-logon-SID-only descriptor. No
/// platform falls back to TCP or a less restrictive endpoint.
pub const DriverTransport = struct {
    allocator: Allocator,
    endpoint: []u8,
    endpoint_inode: ?std.Io.File.INode,
    window: *const Window,
    listener: DriverListener,
    listener_closed: bool = false,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    issue: std.atomic.Value(DriverTransportIssue) = .init(.none),

    mutex: std.Io.Mutex = .init,
    response_ready: std.Io.Condition = .init,
    active_stream: ?DriverConnection = null,
    requests: [max_driver_pending]?DriverRequest = @splat(null),
    request_head: usize = 0,
    request_count: usize = 0,
    responses: [max_driver_pending]?DriverResponse = @splat(null),
    response_head: usize = 0,
    response_count: usize = 0,
    next_token: u64 = 1,

    pub const StartError = Allocator.Error || error{
        UnsupportedPlatform,
        WindowsSecurityUnavailable,
        InvalidEndpoint,
        EndpointTooLong,
        EndpointOccupied,
        EndpointNotSocket,
        EndpointSetupFailed,
        ListenerFailed,
        ThreadSpawnFailed,
    };

    pub const RespondError = Allocator.Error || error{
        Stopped,
        InvalidFrame,
        FrameTooLarge,
        ResponseQueueFull,
    };

    /// Start listening at an explicit local endpoint and spawn the blocking I/O worker.
    pub fn start(allocator: Allocator, endpoint: []const u8, window: *const Window) StartError!*DriverTransport {
        return switch (builtin.os.tag) {
            .windows => startWindows(allocator, endpoint, window),
            .linux, .macos => startUnix(allocator, endpoint, window),
            else => error.UnsupportedPlatform,
        };
    }

    fn startWindows(allocator: Allocator, endpoint: []const u8, window: *const Window) StartError!*DriverTransport {
        try validateWindowsDriverEndpoint(endpoint);
        const listener = try WindowsDriver.createListener(allocator, endpoint);
        errdefer WindowsDriver.closeListener(listener);

        const self = try allocator.create(DriverTransport);
        errdefer allocator.destroy(self);
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        errdefer allocator.free(owned_endpoint);
        self.* = .{
            .allocator = allocator,
            .endpoint = owned_endpoint,
            .endpoint_inode = null,
            .window = window,
            .listener = listener,
        };
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch return error.ThreadSpawnFailed;
        return self;
    }

    fn startUnix(allocator: Allocator, endpoint: []const u8, window: *const Window) StartError!*DriverTransport {
        try validateDriverEndpoint(endpoint);
        if (endpoint.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) {
            return error.EndpointTooLong;
        }
        const io = driverIo();
        try prepareDriverEndpoint(io, endpoint);

        const address = std.Io.net.UnixAddress.init(endpoint) catch return error.EndpointTooLong;
        var listener = address.listen(io, .{}) catch return error.ListenerFailed;
        errdefer listener.deinit(io);
        errdefer removeOwnedDriverEndpoint(io, endpoint, null);

        std.Io.Dir.cwd().setFilePermissions(
            io,
            endpoint,
            posixPermissions(0o600),
            .{ .follow_symlinks = false },
        ) catch return error.EndpointSetupFailed;
        const endpoint_stat = std.Io.Dir.cwd().statFile(
            io,
            endpoint,
            .{ .follow_symlinks = false },
        ) catch return error.EndpointSetupFailed;
        if (endpoint_stat.kind != .unix_domain_socket) return error.EndpointSetupFailed;

        const self = try allocator.create(DriverTransport);
        errdefer allocator.destroy(self);
        const owned_endpoint = try allocator.dupe(u8, endpoint);
        errdefer allocator.free(owned_endpoint);
        self.* = .{
            .allocator = allocator,
            .endpoint = owned_endpoint,
            .endpoint_inode = endpoint_stat.inode,
            .window = window,
            .listener = listener,
        };
        self.thread = std.Thread.spawn(.{}, workerMain, .{self}) catch return error.ThreadSpawnFailed;
        return self;
    }

    /// Take one request without blocking. Ownership of its bytes transfers to the caller.
    pub fn takeRequest(self: *DriverTransport) ?DriverRequest {
        const io = driverIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.request_count == 0) return null;
        const slot = &self.requests[self.request_head];
        const request = slot.*.?;
        slot.* = null;
        self.request_head = (self.request_head + 1) % max_driver_pending;
        self.request_count -= 1;
        return request;
    }

    /// Copy and queue one response for the request `token`.
    ///
    /// `bytes` excludes the newline delimiter and may not contain one. The worker owns the copy
    /// after this call returns.
    pub fn respond(self: *DriverTransport, token: u64, bytes: []const u8) RespondError!void {
        if (self.stopping.load(.acquire)) return error.Stopped;
        if (bytes.len > max_driver_response_bytes) return error.FrameTooLarge;
        if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, '\n') != null) return error.InvalidFrame;

        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        const io = driverIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping.load(.acquire)) return error.Stopped;
        if (self.response_count == max_driver_pending) return error.ResponseQueueFull;
        const tail = (self.response_head + self.response_count) % max_driver_pending;
        self.responses[tail] = .{ .token = token, .bytes = owned };
        self.response_count += 1;
        self.response_ready.signal(io);
    }

    /// Take the first unread asynchronous transport issue without blocking.
    pub fn takeIssue(self: *DriverTransport) ?DriverTransportIssue {
        const issue = self.issue.swap(.none, .acq_rel);
        return if (issue == .none) null else issue;
    }

    /// Wake blocking I/O, stop the worker and join it. Windows handles are closed after the join;
    /// the Unix listener remains owned until `deinit`. Safe to call more than once.
    pub fn stop(self: *DriverTransport) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        const io = driverIo();

        if (comptime builtin.os.tag == .windows) {
            WindowsDriver.cancel(self.listener);
        } else {
            // `shutdown` is the cancellation operation documented for a blocked Server.accept.
            const listener_stream: std.Io.net.Stream = .{ .socket = self.listener.socket };
            self.shutdownForStop(listener_stream);
            // Darwin's shutdown(2) refuses a listening socket with ENOTCONN and leaves a blocked
            // accept(2) asleep, where Linux's wakes it, so the join below would wait forever. One
            // connection to the transport's own endpoint wakes it there; the worker sees
            // `stopping` and closes that connection unserved.
            if (comptime builtin.os.tag != .linux) {
                var waker = DriverClient.connect(self.endpoint) catch null;
                if (waker) |*client| client.deinit();
            }
        }

        self.mutex.lockUncancelable(io);
        if (comptime builtin.os.tag != .windows) {
            if (self.active_stream) |stream| self.shutdownForStop(stream);
        }
        self.response_ready.broadcast(io);
        self.mutex.unlock(io);

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (comptime builtin.os.tag == .windows) {
            WindowsDriver.closeListener(self.listener);
            self.listener_closed = true;
        }
    }

    /// Stop the worker, close the listener, remove only the socket this instance created, and free
    /// all messages still owned by the transport.
    pub fn deinit(self: *DriverTransport) void {
        self.stop();
        const io = driverIo();
        if (comptime builtin.os.tag == .windows) {
            if (!self.listener_closed) WindowsDriver.closeListener(self.listener);
        } else {
            self.listener.deinit(io);
            removeOwnedDriverEndpoint(io, self.endpoint, self.endpoint_inode);
        }

        while (self.takeRequest()) |request_value| {
            var request = request_value;
            request.deinit(self.allocator);
        }
        self.mutex.lockUncancelable(io);
        while (self.response_count != 0) {
            const slot = &self.responses[self.response_head];
            self.allocator.free(slot.*.?.bytes);
            slot.* = null;
            self.response_head = (self.response_head + 1) % max_driver_pending;
            self.response_count -= 1;
        }
        self.mutex.unlock(io);

        const allocator = self.allocator;
        allocator.free(self.endpoint);
        allocator.destroy(self);
    }

    fn workerMain(self: *DriverTransport) void {
        if (comptime builtin.os.tag == .windows) {
            return self.workerMainWindows();
        }
        return self.workerMainUnix();
    }

    fn workerMainUnix(self: *DriverTransport) void {
        const io = driverIo();
        while (!self.stopping.load(.acquire)) {
            const stream = self.listener.accept(io) catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.accept_failed);
                return;
            };
            if (self.stopping.load(.acquire)) {
                // The connection `stop` makes to wake this accept where shutdown cannot.
                stream.close(io);
                return;
            }

            self.mutex.lockUncancelable(io);
            self.active_stream = stream;
            self.mutex.unlock(io);

            self.serveUnix(stream);

            self.mutex.lockUncancelable(io);
            self.active_stream = null;
            self.mutex.unlock(io);
            stream.close(io);
        }
    }

    fn workerMainWindows(self: *DriverTransport) void {
        while (!self.stopping.load(.acquire)) {
            WindowsDriver.connect(self.listener) catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.accept_failed);
                return;
            };

            self.mutex.lockUncancelable(driverIo());
            self.active_stream = self.listener.pipe;
            self.mutex.unlock(driverIo());

            self.serveWindows();

            self.mutex.lockUncancelable(driverIo());
            self.active_stream = null;
            self.mutex.unlock(driverIo());
            WindowsDriver.disconnect(self.listener);
        }
    }

    fn serveUnix(self: *DriverTransport, stream: std.Io.net.Stream) void {
        const read_buffer = self.allocator.alloc(u8, max_driver_request_bytes + 1) catch {
            self.reportIssue(.connection_failed);
            return;
        };
        defer self.allocator.free(read_buffer);
        var reader = stream.reader(driverIo(), read_buffer);

        while (!self.stopping.load(.acquire)) {
            const framed = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    if (reader.interface.bufferedLen() != 0) self.reportIssue(.malformed_frame);
                    return;
                },
                error.StreamTooLong => {
                    self.reportIssue(.frame_too_large);
                    return;
                },
                error.ReadFailed => {
                    if (!self.stopping.load(.acquire)) self.reportIssue(.connection_failed);
                    return;
                },
            };
            const frame = framed[0 .. framed.len - 1];
            if (frame.len == 0) {
                self.reportIssue(.malformed_frame);
                return;
            }

            const owned = self.allocator.dupe(u8, frame) catch {
                self.reportIssue(.connection_failed);
                return;
            };
            const token = self.nextRequestToken();
            if (!self.enqueueRequest(.{ .token = token, .bytes = owned })) {
                self.allocator.free(owned);
                self.reportIssue(.request_queue_full);
                return;
            }
            self.wakeMain();

            const response = self.waitForResponse(token) orelse return;
            defer self.allocator.free(response.bytes);
            var write_buffer: [4096]u8 = undefined;
            var writer = stream.writer(driverIo(), &write_buffer);
            writer.interface.writeAll(response.bytes) catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.connection_failed);
                return;
            };
            writer.interface.writeByte('\n') catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.connection_failed);
                return;
            };
            writer.interface.flush() catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.connection_failed);
                return;
            };
        }
    }

    fn serveWindows(self: *DriverTransport) void {
        const read_buffer = self.allocator.alloc(u8, max_driver_request_bytes + 1) catch {
            self.reportIssue(.connection_failed);
            return;
        };
        defer self.allocator.free(read_buffer);
        var used: usize = 0;

        while (!self.stopping.load(.acquire)) {
            while (std.mem.indexOfScalar(u8, read_buffer[0..used], '\n') == null) {
                if (used == read_buffer.len) {
                    self.reportIssue(.frame_too_large);
                    return;
                }
                const count = WindowsDriver.overlappedRead(self.listener, read_buffer[used..]) catch |err| {
                    if (!self.stopping.load(.acquire)) switch (err) {
                        error.Disconnected => if (used != 0) self.reportIssue(.malformed_frame),
                        error.Cancelled, error.Failed => self.reportIssue(.connection_failed),
                    };
                    return;
                };
                if (count == 0) {
                    if (used != 0) self.reportIssue(.malformed_frame);
                    return;
                }
                used += count;
            }

            const delimiter = std.mem.indexOfScalar(u8, read_buffer[0..used], '\n').?;
            if (delimiter == 0) {
                self.reportIssue(.malformed_frame);
                return;
            }
            if (delimiter > max_driver_request_bytes) {
                self.reportIssue(.frame_too_large);
                return;
            }
            const owned = self.allocator.dupe(u8, read_buffer[0..delimiter]) catch {
                self.reportIssue(.connection_failed);
                return;
            };
            const remaining = used - delimiter - 1;
            std.mem.copyForwards(u8, read_buffer[0..remaining], read_buffer[delimiter + 1 .. used]);
            used = remaining;

            const token = self.nextRequestToken();
            if (!self.enqueueRequest(.{ .token = token, .bytes = owned })) {
                self.allocator.free(owned);
                self.reportIssue(.request_queue_full);
                return;
            }
            self.wakeMain();

            const response = self.waitForResponse(token) orelse return;
            defer self.allocator.free(response.bytes);
            WindowsDriver.overlappedWriteAll(self.listener, response.bytes) catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.connection_failed);
                return;
            };
            WindowsDriver.overlappedWriteAll(self.listener, "\n") catch {
                if (!self.stopping.load(.acquire)) self.reportIssue(.connection_failed);
                return;
            };
        }
    }

    fn nextRequestToken(self: *DriverTransport) u64 {
        const token = self.next_token;
        self.next_token +%= 1;
        if (self.next_token == 0) self.next_token = 1;
        return token;
    }

    fn enqueueRequest(self: *DriverTransport, request: DriverRequest) bool {
        const io = driverIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.request_count == max_driver_pending) return false;
        const tail = (self.request_head + self.request_count) % max_driver_pending;
        self.requests[tail] = request;
        self.request_count += 1;
        return true;
    }

    fn waitForResponse(self: *DriverTransport, token: u64) ?DriverResponse {
        const io = driverIo();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        while (!self.stopping.load(.acquire)) {
            if (self.response_count == 0) {
                self.response_ready.waitUncancelable(io, &self.mutex);
                continue;
            }
            const slot = &self.responses[self.response_head];
            const response = slot.*.?;
            slot.* = null;
            self.response_head = (self.response_head + 1) % max_driver_pending;
            self.response_count -= 1;
            if (response.token == token) return response;
            self.allocator.free(response.bytes);
            self.recordIssue(.response_token_mismatch);
        }
        return null;
    }

    fn wakeMain(self: *DriverTransport) void {
        self.window.postDriverWake() catch self.recordIssue(.wake_failed);
    }

    fn reportIssue(self: *DriverTransport, issue: DriverTransportIssue) void {
        self.recordIssue(issue);
        self.wakeMain();
    }

    fn recordIssue(self: *DriverTransport, issue: DriverTransportIssue) void {
        _ = self.issue.cmpxchgStrong(.none, issue, .release, .monotonic);
    }

    fn shutdownForStop(self: *DriverTransport, stream: std.Io.net.Stream) void {
        stream.shutdown(driverIo(), .both) catch |err| switch (err) {
            // A peer that already disconnected and a listener with no accepted connection both
            // need no cancellation; closing the handles after join completes cleanup.
            error.SocketUnconnected => {},
            else => self.recordIssue(.connection_failed),
        };
    }
};

/// A small blocking client for raw platform/self-checks.
///
/// This is intentionally protocol-agnostic: it connects to the same local endpoint, writes one
/// newline-delimited frame, and reads one response. Higher layers remain responsible for JSON-RPC.
pub const DriverClient = struct {
    stream: DriverConnection,

    pub const ConnectError = error{
        UnsupportedPlatform,
        WindowsSecurityUnavailable,
        InvalidEndpoint,
        EndpointTooLong,
        ConnectionFailed,
    };
    pub const ExchangeError = Allocator.Error || error{
        InvalidFrame,
        FrameTooLarge,
        ConnectionFailed,
        MalformedFrame,
    };

    pub fn connect(endpoint: []const u8) ConnectError!DriverClient {
        return switch (builtin.os.tag) {
            .windows => connectWindows(endpoint),
            .linux, .macos => connectUnix(endpoint),
            else => error.UnsupportedPlatform,
        };
    }

    fn connectWindows(endpoint: []const u8) ConnectError!DriverClient {
        validateWindowsDriverEndpoint(endpoint) catch |err| return switch (err) {
            error.InvalidEndpoint => error.InvalidEndpoint,
            error.EndpointTooLong => error.EndpointTooLong,
        };
        return .{ .stream = try WindowsDriver.openClient(endpoint) };
    }

    fn connectUnix(endpoint: []const u8) ConnectError!DriverClient {
        validateDriverEndpoint(endpoint) catch |err| return switch (err) {
            error.InvalidEndpoint => error.InvalidEndpoint,
        };
        if (endpoint.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) {
            return error.EndpointTooLong;
        }
        const address = std.Io.net.UnixAddress.init(endpoint) catch return error.EndpointTooLong;
        return .{ .stream = address.connect(driverIo()) catch return error.ConnectionFailed };
    }

    pub fn deinit(self: *DriverClient) void {
        if (comptime builtin.os.tag == .windows) {
            std.os.windows.CloseHandle(self.stream);
        } else {
            self.stream.close(driverIo());
        }
        self.* = undefined;
    }

    /// Send and receive exactly one frame. The caller owns the returned bytes.
    pub fn exchange(self: *DriverClient, allocator: Allocator, bytes: []const u8) ExchangeError![]u8 {
        if (bytes.len > max_driver_request_bytes) return error.FrameTooLarge;
        if (bytes.len == 0 or std.mem.indexOfScalar(u8, bytes, '\n') != null) return error.InvalidFrame;

        if (comptime builtin.os.tag == .windows) return self.exchangeWindows(allocator, bytes);
        return self.exchangeUnix(allocator, bytes);
    }

    fn exchangeUnix(self: *DriverClient, allocator: Allocator, bytes: []const u8) ExchangeError![]u8 {
        var write_buffer: [4096]u8 = undefined;
        var writer = self.stream.writer(driverIo(), &write_buffer);
        writer.interface.writeAll(bytes) catch return error.ConnectionFailed;
        writer.interface.writeByte('\n') catch return error.ConnectionFailed;
        writer.interface.flush() catch return error.ConnectionFailed;

        const read_buffer = try allocator.alloc(u8, max_driver_response_bytes + 1);
        defer allocator.free(read_buffer);
        var reader = self.stream.reader(driverIo(), read_buffer);
        const framed = reader.interface.takeDelimiterInclusive('\n') catch |err| return switch (err) {
            error.EndOfStream => error.MalformedFrame,
            error.StreamTooLong => error.FrameTooLarge,
            error.ReadFailed => error.ConnectionFailed,
        };
        const response = framed[0 .. framed.len - 1];
        if (response.len == 0) return error.MalformedFrame;
        return allocator.dupe(u8, response);
    }

    fn exchangeWindows(self: *DriverClient, allocator: Allocator, bytes: []const u8) ExchangeError![]u8 {
        WindowsDriver.clientWriteAll(self.stream, bytes) catch return error.ConnectionFailed;
        WindowsDriver.clientWriteAll(self.stream, "\n") catch return error.ConnectionFailed;

        const read_buffer = try allocator.alloc(u8, max_driver_response_bytes + 1);
        defer allocator.free(read_buffer);
        var used: usize = 0;
        while (std.mem.indexOfScalar(u8, read_buffer[0..used], '\n') == null) {
            if (used == read_buffer.len) return error.FrameTooLarge;
            const count = WindowsDriver.clientRead(self.stream, read_buffer[used..]) catch |err| return switch (err) {
                error.EndOfStream => error.MalformedFrame,
                error.ConnectionFailed => error.ConnectionFailed,
            };
            used += count;
        }
        const delimiter = std.mem.indexOfScalar(u8, read_buffer[0..used], '\n').?;
        if (delimiter == 0) return error.MalformedFrame;
        if (delimiter > max_driver_response_bytes) return error.FrameTooLarge;
        return allocator.dupe(u8, read_buffer[0..delimiter]);
    }
};

/// A local, current-user-only listener for a server that owns its own accept loop and serves many
/// clients at once: a filesystem AF_UNIX socket on Linux and macOS, a protected multi-instance
/// named pipe on Windows (TASK-82).
///
/// The TASK-60 control API serves many short-lived harness clients concurrently with reply
/// deadlines, so it cannot reuse the single-connection, window-bound `DriverTransport`; it reuses
/// the endpoint discipline and, on Windows, the driver's pipe seam:
///
/// - Linux and macOS: `listen` refuses a parent directory that grants any group or other
///   permission, so the endpoint always sits inside a private (0700) run directory, and leaves
///   the socket itself 0600. A live socket is never replaced; a stale one is.
/// - Windows: `endpoint` is an exact `\\.\pipe\<name>` path. Every instance carries the driver
///   pipe's descriptor (only the current logon SID may read or write) and rejects remote
///   clients; the first instance refuses a name another process already holds, so a squatter
///   cannot pre-create the endpoint. One instance always waits for the next client.
///
/// No platform falls back to TCP.
///
/// Threads: `listen` and `deinit` run on the owning thread; `accept` blocks on one worker, which
/// the owner wakes with `cancelAccept` before `deinit`.
pub const LocalSocketListener = struct {
    impl: Impl,

    const Impl = if (builtin.os.tag == .windows) WindowsPipeServer else PosixSocketServer;

    pub const ListenError = DriverTransport.StartError || error{ParentNotPrivate};
    pub const AcceptError = error{ Cancelled, AcceptFailed };

    /// Listen at `endpoint`. On Linux and macOS its parent directory must already exist and be
    /// private.
    pub fn listen(io: std.Io, endpoint: []const u8) ListenError!LocalSocketListener {
        return .{ .impl = try Impl.listen(io, endpoint) };
    }

    /// Block until the next client connects. The stream is the caller's to `close`.
    pub fn accept(self: *LocalSocketListener, io: std.Io) AcceptError!LocalStream {
        return self.impl.accept(io);
    }

    /// Wake a blocked `accept` from another thread; every later `accept` fails with `Cancelled`
    /// (Windows) or an accept error (POSIX). Darwin's shutdown does not wake a blocked accept, so
    /// a POSIX caller there also connects once to its own endpoint (see `control.Server.deinit`).
    pub fn cancelAccept(self: *LocalSocketListener, io: std.Io) void {
        self.impl.cancelAccept(io);
    }

    /// Close the listener and, on POSIX, remove `endpoint` only if it is still the socket
    /// `listen` made.
    pub fn deinit(self: *LocalSocketListener, io: std.Io, endpoint: []const u8) void {
        self.impl.deinit(io, endpoint);
        self.* = undefined;
    }
};

/// One accepted connection of a `LocalSocketListener`. `read` and `writeAll` run on the one thread
/// serving it; `cancel` may be called from any thread to wake a blocked `read`; `close` once,
/// after its thread is done.
pub const LocalStream = struct {
    impl: if (builtin.os.tag == .windows) WindowsDriver.Listener else std.Io.net.Stream,

    pub const ReadError = error{ReadFailed};
    pub const WriteError = error{WriteFailed};

    /// Read what is available into `dest` (blocking until something is): 0 at end of stream.
    pub fn read(self: *const LocalStream, io: std.Io, dest: []u8) ReadError!usize {
        if (dest.len == 0) return 0;
        if (comptime builtin.os.tag == .windows) {
            return WindowsDriver.overlappedRead(self.impl, dest) catch |err| switch (err) {
                error.Disconnected => 0,
                error.Cancelled, error.Failed => error.ReadFailed,
            };
        } else {
            var vector: [1][]u8 = .{dest};
            return io.vtable.netRead(io.userdata, self.impl.socket.handle, &vector) catch error.ReadFailed;
        }
    }

    pub fn writeAll(self: *const LocalStream, io: std.Io, bytes: []const u8) WriteError!void {
        if (comptime builtin.os.tag == .windows) {
            WindowsDriver.overlappedWriteAll(self.impl, bytes) catch return error.WriteFailed;
        } else {
            var buffer: [256]u8 = undefined;
            var writer = self.impl.writer(io, &buffer);
            writer.interface.writeAll(bytes) catch return error.WriteFailed;
            writer.interface.flush() catch return error.WriteFailed;
        }
    }

    /// End the write side so the client sees end of stream after what was written. A named pipe
    /// has no half-close; the client reads to the end and then sees the pipe close.
    pub fn shutdownSend(self: *const LocalStream, io: std.Io) void {
        if (comptime builtin.os.tag == .windows) return;
        // A peer that already left needs no shutdown.
        self.impl.shutdown(io, .send) catch {};
    }

    /// Wake a `read` or `writeAll` blocked on another thread; the stream stays open.
    pub fn cancel(self: *const LocalStream, io: std.Io) void {
        if (comptime builtin.os.tag == .windows) {
            WindowsDriver.cancel(self.impl);
        } else {
            // Shutdown only cancels a blocked read; a peer that already left needs no cancelling.
            self.impl.shutdown(io, .both) catch {};
        }
    }

    pub fn close(self: *const LocalStream, io: std.Io) void {
        if (comptime builtin.os.tag == .windows) {
            WindowsDriver.closeListener(self.impl);
        } else {
            self.impl.close(io);
        }
    }
};

const PosixSocketServer = struct {
    server: std.Io.net.Server,
    endpoint_inode: std.Io.File.INode,

    fn listen(io: std.Io, endpoint: []const u8) LocalSocketListener.ListenError!PosixSocketServer {
        if (comptime builtin.os.tag == .windows) unreachable;
        try validateDriverEndpoint(endpoint);
        if (endpoint.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) {
            return error.EndpointTooLong;
        }
        const parent = std.fs.path.dirname(endpoint) orelse return error.InvalidEndpoint;
        const parent_stat = std.Io.Dir.cwd().statFile(io, parent, .{ .follow_symlinks = false }) catch {
            return error.EndpointSetupFailed;
        };
        if (parent_stat.kind != .directory) return error.EndpointSetupFailed;
        if (parent_stat.permissions.toMode() & 0o077 != 0) return error.ParentNotPrivate;
        try prepareDriverEndpoint(io, endpoint);

        const address = std.Io.net.UnixAddress.init(endpoint) catch return error.EndpointTooLong;
        var server = address.listen(io, .{}) catch return error.ListenerFailed;
        errdefer server.deinit(io);
        errdefer removeOwnedDriverEndpoint(io, endpoint, null);

        std.Io.Dir.cwd().setFilePermissions(
            io,
            endpoint,
            posixPermissions(0o600),
            .{ .follow_symlinks = false },
        ) catch return error.EndpointSetupFailed;
        const stat = std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }) catch {
            return error.EndpointSetupFailed;
        };
        if (stat.kind != .unix_domain_socket) return error.EndpointSetupFailed;
        return .{ .server = server, .endpoint_inode = stat.inode };
    }

    fn accept(self: *PosixSocketServer, io: std.Io) LocalSocketListener.AcceptError!LocalStream {
        const stream = self.server.accept(io) catch return error.AcceptFailed;
        return .{ .impl = stream };
    }

    fn cancelAccept(self: *PosixSocketServer, io: std.Io) void {
        // `shutdown` is the cancellation operation documented for a blocked Server.accept; a
        // listener with no connection needs nothing more.
        const listener_stream: std.Io.net.Stream = .{ .socket = self.server.socket };
        listener_stream.shutdown(io, .both) catch {};
    }

    fn deinit(self: *PosixSocketServer, io: std.Io, endpoint: []const u8) void {
        self.server.deinit(io);
        removeOwnedDriverEndpoint(io, endpoint, self.endpoint_inode);
    }
};

/// The Windows side of `LocalSocketListener`: one pipe name, many instances. `pending` is the
/// instance waiting for the next client; `accept` hands a connected instance to its caller and
/// creates the next one before returning, so the name never disappears between clients.
const WindowsPipeServer = struct {
    name: [WindowsDriver.max_pipe_path_chars + 1]u16,
    name_len: usize,
    /// From `ConvertStringSecurityDescriptorToSecurityDescriptorW`; `LocalFree`d by `deinit`.
    descriptor: *anyopaque,
    /// Set by `cancelAccept`; every connect waits on it.
    stop_event: std.os.windows.HANDLE,
    pending: ?Pending,

    const Pending = struct { pipe: std.os.windows.HANDLE, event: std.os.windows.HANDLE };

    fn listen(io: std.Io, endpoint: []const u8) LocalSocketListener.ListenError!WindowsPipeServer {
        _ = io;
        if (comptime builtin.os.tag != .windows) unreachable;
        try validateWindowsDriverEndpoint(endpoint);
        const descriptor = try WindowsDriver.createSecurityDescriptor(std.heap.page_allocator);
        errdefer _ = WindowsDriver.LocalFree(descriptor);
        var self: WindowsPipeServer = .{
            .name = undefined,
            .name_len = endpoint.len,
            .descriptor = descriptor,
            .stop_event = undefined,
            .pending = null,
        };
        _ = WindowsDriver.pipeName(endpoint, &self.name);
        const first = try WindowsDriver.createInstance(self.nameZ(), descriptor, true);
        errdefer {
            std.os.windows.CloseHandle(first.event);
            std.os.windows.CloseHandle(first.pipe);
        }
        self.stop_event = WindowsDriver.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.ListenerFailed;
        self.pending = .{ .pipe = first.pipe, .event = first.event };
        return self;
    }

    fn nameZ(self: *const WindowsPipeServer) [:0]const u16 {
        return self.name[0..self.name_len :0];
    }

    fn accept(self: *WindowsPipeServer, io: std.Io) LocalSocketListener.AcceptError!LocalStream {
        _ = io;
        if (comptime builtin.os.tag != .windows) unreachable;
        const windows = std.os.windows;
        const instance = self.pending orelse blk: {
            const made = WindowsDriver.createInstance(self.nameZ(), self.descriptor, false) catch return error.AcceptFailed;
            self.pending = .{ .pipe = made.pipe, .event = made.event };
            break :blk self.pending.?;
        };
        WindowsDriver.connect(.{ .pipe = instance.pipe, .event = instance.event, .stop_event = self.stop_event }) catch |err| {
            // The instance is unusable after a failed or cancelled connect; a fresh one replaces
            // it on the next call.
            windows.CloseHandle(instance.event);
            windows.CloseHandle(instance.pipe);
            self.pending = null;
            return switch (err) {
                error.Cancelled => error.Cancelled,
                error.Disconnected, error.Failed => error.AcceptFailed,
            };
        };
        self.pending = null;
        if (WindowsDriver.createInstance(self.nameZ(), self.descriptor, false)) |next| {
            self.pending = .{ .pipe = next.pipe, .event = next.event };
        } else |_| {
            // Retried by the next `accept`; this connection is still served.
        }
        const stream_stop = WindowsDriver.CreateEventW(null, .TRUE, .FALSE, null) orelse {
            windows.CloseHandle(instance.event);
            windows.CloseHandle(instance.pipe);
            return error.AcceptFailed;
        };
        return .{ .impl = .{ .pipe = instance.pipe, .event = instance.event, .stop_event = stream_stop } };
    }

    fn cancelAccept(self: *WindowsPipeServer, io: std.Io) void {
        _ = io;
        if (comptime builtin.os.tag != .windows) unreachable;
        _ = WindowsDriver.SetEvent(self.stop_event);
    }

    fn deinit(self: *WindowsPipeServer, io: std.Io, endpoint: []const u8) void {
        _ = io;
        _ = endpoint;
        if (comptime builtin.os.tag != .windows) unreachable;
        if (self.pending) |instance| {
            std.os.windows.CloseHandle(instance.event);
            std.os.windows.CloseHandle(instance.pipe);
        }
        std.os.windows.CloseHandle(self.stop_event);
        _ = WindowsDriver.LocalFree(self.descriptor);
    }
};

/// The current user's identity for naming per-user local endpoints: the user SID's text on
/// Windows (`S-1-5-21-…`), written into `buffer`. Null elsewhere, and when it cannot be read.
pub fn currentUserId(buffer: []u8) ?[]const u8 {
    if (comptime builtin.os.tag != .windows) return null;
    return WindowsDriver.currentUserSid(buffer);
}

pub const AppendError = error{ InvalidPath, OpenFailed, WriteFailed };

/// Append `bytes` to the file at `path` with one append-mode write, creating it (0600 on POSIX)
/// when missing: `O_APPEND` on POSIX, `FILE_APPEND_DATA` on Windows. Writers appending whole
/// lines this way never interleave or overwrite each other's lines, which is what the agent
/// event files rely on (the hook relay appends with `cat >>`, `conduit control` and the control
/// endpoint append beside it).
pub fn appendToFile(path: []const u8, bytes: []const u8) AppendError!void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var wide_buffer: [std.fs.max_path_bytes + 1]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(&wide_buffer, path) catch return error.InvalidPath;
        if (length >= wide_buffer.len) return error.InvalidPath;
        wide_buffer[length] = 0;
        const file_append_data: windows.DWORD = 0x0004;
        const file_share_read_write: windows.DWORD = 0x00000001 | 0x00000002;
        const open_always: windows.DWORD = 4;
        const handle = WindowsDriver.CreateFileW(
            wide_buffer[0..length :0].ptr,
            file_append_data,
            file_share_read_write,
            null,
            open_always,
            0,
            null,
        );
        if (handle == windows.INVALID_HANDLE_VALUE) return error.OpenFailed;
        defer windows.CloseHandle(handle);
        var transferred: windows.DWORD = 0;
        if (WindowsDriver.WriteFile(handle, bytes.ptr, @intCast(bytes.len), &transferred, null) == .FALSE or
            transferred != bytes.len) return error.WriteFailed;
    } else {
        const fd = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, 0o600) catch
            return error.OpenFailed;
        defer _ = std.posix.system.close(fd);
        const written = std.posix.system.write(fd, bytes.ptr, bytes.len);
        if (std.posix.errno(written) != .SUCCESS or @as(usize, @intCast(written)) != bytes.len) return error.WriteFailed;
    }
}

fn driverIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn validateDriverEndpoint(endpoint: []const u8) error{InvalidEndpoint}!void {
    if (endpoint.len == 0 or std.mem.indexOfScalar(u8, endpoint, 0) != null) {
        return error.InvalidEndpoint;
    }
}

fn validateWindowsDriverEndpoint(endpoint: []const u8) error{ InvalidEndpoint, EndpointTooLong }!void {
    if (!std.mem.startsWith(u8, endpoint, WindowsDriver.pipe_prefix)) return error.InvalidEndpoint;
    if (endpoint.len == WindowsDriver.pipe_prefix.len) return error.InvalidEndpoint;
    if (endpoint.len > WindowsDriver.max_pipe_path_chars) return error.EndpointTooLong;
    const name = endpoint[WindowsDriver.pipe_prefix.len..];
    for (name) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.' and byte != '_' and byte != '-') {
            return error.InvalidEndpoint;
        }
    }
}

fn posixPermissions(mode: std.posix.mode_t) std.Io.File.Permissions {
    if (comptime builtin.os.tag == .windows) {
        unreachable;
    } else {
        return .fromMode(mode);
    }
}

fn prepareDriverEndpoint(io: std.Io, endpoint: []const u8) DriverTransport.StartError!void {
    const parent = std.fs.path.dirname(endpoint) orelse ".";
    _ = std.Io.Dir.cwd().createDirPathStatus(io, parent, posixPermissions(0o700)) catch {
        return error.EndpointSetupFailed;
    };

    const stat = std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return error.EndpointSetupFailed,
    };
    if (stat.kind != .unix_domain_socket) return error.EndpointNotSocket;
    if (try driverSocketIsLive(endpoint)) return error.EndpointOccupied;
    std.Io.Dir.cwd().deleteFile(io, endpoint) catch return error.EndpointSetupFailed;
}

/// Probe an existing AF_UNIX socket before treating it as stale.
///
/// The Zig 0.16 `UnixAddress.connect` error set currently folds `ECONNREFUSED` into `Unexpected`,
/// which cannot safely distinguish a stale pathname from a live endpoint that must not be unlinked.
/// This narrow syscall seam retains that one errno distinction on Linux and macOS.
fn driverSocketIsLive(endpoint: []const u8) error{EndpointSetupFailed}!bool {
    if (endpoint.len >= @sizeOf(@FieldType(std.posix.sockaddr.un, "path"))) {
        return error.EndpointSetupFailed;
    }
    var address: std.posix.sockaddr.un = std.mem.zeroes(std.posix.sockaddr.un);
    address.family = std.posix.AF.UNIX;
    @memcpy(address.path[0..endpoint.len], endpoint);
    address.path[endpoint.len] = 0;
    const address_len: std.posix.socklen_t = @intCast(@offsetOf(std.posix.sockaddr.un, "path") + endpoint.len + 1);
    if (@hasField(std.posix.sockaddr.un, "len")) address.len = @intCast(address_len);

    const socket_result = std.posix.system.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    if (std.posix.errno(socket_result) != .SUCCESS) return error.EndpointSetupFailed;
    const socket: std.posix.socket_t = @intCast(socket_result);
    defer _ = std.posix.system.close(socket);

    while (true) {
        const result = std.posix.system.connect(
            socket,
            @ptrCast(&address),
            address_len,
        );
        switch (std.posix.errno(result)) {
            .SUCCESS => return true,
            .INTR => continue,
            .CONNREFUSED, .NOENT => return false,
            else => return error.EndpointSetupFailed,
        }
    }
}

/// Remove `endpoint` only when it is still the socket created by this transport.
/// A replaced file or socket is somebody else's and is left untouched.
fn removeOwnedDriverEndpoint(io: std.Io, endpoint: []const u8, expected_inode: ?std.Io.File.INode) void {
    const stat = std.Io.Dir.cwd().statFile(io, endpoint, .{ .follow_symlinks = false }) catch return;
    if (stat.kind != .unix_domain_socket) return;
    if (expected_inode) |inode| if (stat.inode != inode) return;
    // Cleanup is best-effort after the listener is already closed. A failure leaves a stale socket
    // that the next start can identify safely; there is no live resource left to recover here.
    std.Io.Dir.cwd().deleteFile(io, endpoint) catch return;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestAppMetadataSetter = struct {
    fn accept(name: [*:0]const u8, version: [*:0]const u8, identifier: [*:0]const u8) bool {
        return std.mem.eql(u8, std.mem.span(name), "Test App") and
            std.mem.eql(u8, std.mem.span(version), "1.2.3") and
            std.mem.eql(u8, std.mem.span(identifier), "test.example.app");
    }

    fn reject(_: [*:0]const u8, _: [*:0]const u8, _: [*:0]const u8) bool {
        return false;
    }
};

const TestHintSetter = struct {
    fn accept(name: [*c]const u8, value: [*c]const u8, priority: sdl.SDL_HintPriority) bool {
        return std.mem.eql(u8, std.mem.span(name), "SDL_IME_IMPLEMENTED_UI") and
            std.mem.eql(u8, std.mem.span(value), "composition,candidates") and
            priority == sdl.SDL_HINT_OVERRIDE;
    }

    fn reject(_: [*c]const u8, _: [*c]const u8, _: sdl.SDL_HintPriority) bool {
        return false;
    }
};

test "the embedded window icon is a 64x64 RGBA8 image with real transparency" {
    try testing.expectEqual(window_icon_size * window_icon_size * 4, window_icon.rgba.len);
    var transparent = false;
    var opaque_pixel = false;
    var index: usize = 3;
    while (index < window_icon.rgba.len) : (index += 4) {
        if (window_icon.rgba[index] != 255) transparent = true;
        if (window_icon.rgba[index] != 0) opaque_pixel = true;
    }
    // Neither all-clear nor all-solid: the artwork survived, and so did its alpha channel.
    try testing.expect(transparent);
    try testing.expect(opaque_pixel);
}

test "application metadata forwards caller-owned identity without initializing SDL" {
    const metadata: AppMetadata = .{
        .name = "Test App",
        .version = "1.2.3",
        .identifier = "test.example.app",
    };
    try testing.expect(applyAppMetadata(metadata, TestAppMetadataSetter.accept));
    try testing.expect(!applyAppMetadata(metadata, TestAppMetadataSetter.reject));
}

test "window initialization declares Conduit's implemented IME UI exactly" {
    try setImplementedImeUiHintWith(TestHintSetter.accept);
    try testing.expectError(error.ImeUiHintRejected, setImplementedImeUiHintWith(TestHintSetter.reject));
}

test "every window requests a high-pixel-density OpenGL back buffer" {
    const plain = windowCreationFlags(.{
        .title = "test",
        .logical = .{ .width = 640, .height = 360 },
        .resizable = false,
    });
    try testing.expect(plain & sdl.SDL_WINDOW_OPENGL != 0);
    try testing.expect(plain & sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY != 0);
    try testing.expect(plain & sdl.SDL_WINDOW_RESIZABLE == 0);
    try testing.expect(plain & sdl.SDL_WINDOW_HIDDEN == 0);

    const hidden_resizable = windowCreationFlags(.{
        .title = "test",
        .logical = .{ .width = 640, .height = 360 },
        .hidden = true,
    });
    try testing.expect(hidden_resizable & sdl.SDL_WINDOW_OPENGL != 0);
    try testing.expect(hidden_resizable & sdl.SDL_WINDOW_HIGH_PIXEL_DENSITY != 0);
    try testing.expect(hidden_resizable & sdl.SDL_WINDOW_RESIZABLE != 0);
    try testing.expect(hidden_resizable & sdl.SDL_WINDOW_HIDDEN != 0);
}

test "runtime pixel density keeps fractional evidence and reports failed queries" {
    try testing.expectEqual(@as(?f32, 1.25), reportedPixelDensity(1.25));
    try testing.expectEqual(@as(?f32, 0.5), reportedPixelDensity(0.5));
    try testing.expectEqual(@as(?f32, null), reportedPixelDensity(0));
    try testing.expectEqual(@as(?f32, null), reportedPixelDensity(-1));
    try testing.expectEqual(@as(?f32, null), reportedPixelDensity(std.math.nan(f32)));
    try testing.expectEqual(@as(?f32, null), reportedPixelDensity(std.math.inf(f32)));
}

test "URL validation accepts bounded HTTP and HTTPS targets without opening them" {
    try validateOpenUrl("https://example.test/path?q=one#two");
    try validateOpenUrl("HTTP://localhost:8080/");
    try validateOpenUrl("https://example.test/caf\xc3\xa9");

    var boundary: [max_open_url_bytes]u8 = undefined;
    const prefix = "https://example.test/";
    @memcpy(boundary[0..prefix.len], prefix);
    @memset(boundary[prefix.len..], 'a');
    try validateOpenUrl(&boundary);
}

test "URL validation rejects unsafe malformed and oversized targets without opening them" {
    try testing.expectError(error.InvalidUrl, validateOpenUrl(""));
    try testing.expectError(error.UnsupportedScheme, validateOpenUrl("file:///tmp/secret"));
    try testing.expectError(error.UnsupportedScheme, validateOpenUrl("javascript:alert(1)"));
    try testing.expectError(error.InvalidUrl, validateOpenUrl("https://"));
    try testing.expectError(error.InvalidUrl, validateOpenUrl("http://:8080/path"));
    try testing.expectError(error.InvalidUrl, validateOpenUrl("https://example.test/a b"));
    try testing.expectError(error.InvalidUtf8, validateOpenUrl("https://example.test/\xff"));
    try testing.expectError(error.ControlCharacter, validateOpenUrl("https://example.test/\x00x"));
    try testing.expectError(error.ControlCharacter, validateOpenUrl("https://example.test/\n"));
    try testing.expectError(error.ControlCharacter, validateOpenUrl("https://example.test/\x7f"));
    try testing.expectError(error.ControlCharacter, validateOpenUrl("https://example.test/\xc2\x80"));
    try testing.expectError(error.ControlCharacter, validateOpenUrl("https://example.test/\xe2\x80\xa8"));

    var oversized: [max_open_url_bytes + 1]u8 = undefined;
    const prefix = "https://example.test/";
    @memcpy(oversized[0..prefix.len], prefix);
    @memset(oversized[prefix.len..], 'a');
    try testing.expectError(error.UrlTooLong, validateOpenUrl(&oversized));
}

/// A window event of `kind` for window `id`, as SDL would deliver it. `kind` is taken as written so
/// the tests can pass SDL's own constants where they are spelled.
fn windowEvent(id: sdl.SDL_WindowID, kind: anytype) sdl.SDL_Event {
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    raw.window.type = @intCast(kind);
    raw.window.windowID = id;
    return raw;
}

fn testDriverWindow() !Window {
    if (!sdl.SDL_InitSubSystem(sdl.SDL_INIT_EVENTS)) return error.SkipZigTest;
    const first = sdl.SDL_RegisterEvents(2);
    if (first == std.math.maxInt(u32)) return error.SkipZigTest;
    return .{
        .handle = null,
        .context = null,
        .id = 0,
        .state = State.init(.{ .width = 1, .height = 1 }, .{ .factor = 1 }),
        .fixed_scale = null,
        .owns_video = false,
        .driver_events = .{ .wake = first, .barrier = first + 1 },
    };
}

test "named keys and driver barriers preserve SDL queue order" {
    var window = try testDriverWindow();
    defer sdl.SDL_QuitSubSystem(sdl.SDL_INIT_EVENTS);

    try window.postNamedKey(.left, .{ .ctrl = true }, .press);
    try window.postDriverBarrier(0xf1234567);

    const first = window.pump(1000) orelse return error.TestExpectedEqual;
    try testing.expectEqual(Key.left, first.key.key);
    try testing.expect(first.key.mods.ctrl);
    try testing.expectEqual(KeyAction.press, first.key.action);
    const second = window.pump(1000) orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 0xf1234567), second.driver_barrier);
}

test "driver event translation rejects a different window" {
    const state = State.init(.{ .width = 1, .height = 1 }, .{ .factor = 1 });
    const events: DriverEventTypes = .{ .wake = 0x9000, .barrier = 0x9001 };
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    raw.user.type = events.wake;
    raw.user.windowID = 7;
    try testing.expect(translateWithDriverEvents(raw, 9, state, state, events, .none) == null);
    raw.user.windowID = 9;
    try testing.expectEqual(Event.driver_wake, translateWithDriverEvents(raw, 9, state, state, events, .none).?);
}

test "Windows driver endpoint accepts only an exact local safe pipe name" {
    try validateWindowsDriverEndpoint("\\\\.\\pipe\\conduit-test_1.2");
    try testing.expectError(error.InvalidEndpoint, validateWindowsDriverEndpoint(""));
    try testing.expectError(error.InvalidEndpoint, validateWindowsDriverEndpoint("\\\\.\\pipe\\"));
    try testing.expectError(error.InvalidEndpoint, validateWindowsDriverEndpoint("\\\\server\\pipe\\conduit"));
    try testing.expectError(error.InvalidEndpoint, validateWindowsDriverEndpoint("\\\\?\\pipe\\conduit"));
    try testing.expectError(error.InvalidEndpoint, validateWindowsDriverEndpoint("\\\\.\\pipe\\conduit\\nested"));
    try testing.expectError(error.InvalidEndpoint, validateWindowsDriverEndpoint("\\\\.\\pipe\\conduit:name"));

    var longest: [WindowsDriver.max_pipe_path_chars + 1]u8 = undefined;
    @memcpy(longest[0..WindowsDriver.pipe_prefix.len], WindowsDriver.pipe_prefix);
    @memset(longest[WindowsDriver.pipe_prefix.len..], 'a');
    try validateWindowsDriverEndpoint(longest[0..WindowsDriver.max_pipe_path_chars]);
    try testing.expectError(
        error.EndpointTooLong,
        validateWindowsDriverEndpoint(longest[0 .. WindowsDriver.max_pipe_path_chars + 1]),
    );
}

test "Windows driver security descriptor grants only logon SID read and write" {
    const sddl = try WindowsDriver.buildSddl(testing.allocator, "S-1-5-5-123-456");
    defer testing.allocator.free(sddl);
    try testing.expectEqualStrings("D:P(A;;GRGW;;;S-1-5-5-123-456)", sddl);
}

test "Windows driver pipe flags require first local byte-stream instance" {
    try testing.expectEqual(
        @as(WindowsDriver.DWORD, 0x40080003),
        WindowsDriver.pipe_access_duplex |
            WindowsDriver.file_flag_first_pipe_instance |
            WindowsDriver.file_flag_overlapped,
    );
    try testing.expectEqual(
        @as(WindowsDriver.DWORD, 0x00000008),
        WindowsDriver.pipe_type_byte |
            WindowsDriver.pipe_readmode_byte |
            WindowsDriver.pipe_wait |
            WindowsDriver.pipe_reject_remote_clients,
    );
}

test "driver transport keeps independent request and response bounds" {
    try testing.expectEqual(@as(usize, 1024 * 1024), max_driver_request_bytes);
    try testing.expectEqual(@as(usize, 4 * 1024 * 1024), max_driver_response_bytes);
    try testing.expect(max_driver_response_bytes > max_driver_request_bytes);
}

test "driver transport refuses to replace a non-socket endpoint" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "occupied", .data = "not a socket" });
    const root = try tmp.parent_dir.realPathFileAlloc(testing.io, &tmp.sub_path, testing.allocator);
    defer testing.allocator.free(root);
    const endpoint = try std.fs.path.join(testing.allocator, &.{ root, "occupied" });
    defer testing.allocator.free(endpoint);
    var unused_window: Window = undefined;

    try testing.expectError(
        error.EndpointNotSocket,
        DriverTransport.start(testing.allocator, endpoint, &unused_window),
    );
    const contents = try tmp.dir.readFileAlloc(testing.io, "occupied", testing.allocator, .limited(64));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings("not a socket", contents);
}

const DriverClientTest = struct {
    endpoint: []const u8,
    expected_response_bytes: usize,
    ok: std.atomic.Value(bool) = .init(false),

    fn run(self: *DriverClientTest) void {
        var client = DriverClient.connect(self.endpoint) catch return;
        defer client.deinit();
        for (0..2) |_| {
            const response = client.exchange(std.heap.page_allocator, "request") catch return;
            defer std.heap.page_allocator.free(response);
            if (response.len != self.expected_response_bytes or !std.mem.allEqual(u8, response, 'r')) return;
        }
        self.ok.store(true, .release);
    }
};

test "driver transport hands a framed request to the main thread and returns its response" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const endpoint = if (builtin.os.tag == .windows) endpoint: {
        break :endpoint try std.fmt.allocPrint(
            testing.allocator,
            "\\\\.\\pipe\\conduit-platform-test-{d}",
            .{std.os.windows.GetCurrentProcessId()},
        );
    } else endpoint: {
        const root = try tmp.parent_dir.realPathFileAlloc(testing.io, &tmp.sub_path, testing.allocator);
        defer testing.allocator.free(root);
        break :endpoint try std.fs.path.join(testing.allocator, &.{ root, "driver.sock" });
    };
    defer testing.allocator.free(endpoint);

    var window = try testDriverWindow();
    defer sdl.SDL_QuitSubSystem(sdl.SDL_INIT_EVENTS);
    const transport = try DriverTransport.start(testing.allocator, endpoint, &window);
    defer transport.deinit();

    if (builtin.os.tag != .windows) {
        const stat = try std.Io.Dir.cwd().statFile(testing.io, endpoint, .{ .follow_symlinks = false });
        try testing.expectEqual(std.Io.File.Kind.unix_domain_socket, stat.kind);
        try testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
    try testing.expectError(
        error.EndpointOccupied,
        DriverTransport.start(testing.allocator, endpoint, &window),
    );

    const response = try testing.allocator.alloc(u8, max_driver_request_bytes + 1);
    defer testing.allocator.free(response);
    @memset(response, 'r');
    var client_test: DriverClientTest = .{
        .endpoint = endpoint,
        .expected_response_bytes = response.len,
    };
    var client_thread: ?std.Thread = try std.Thread.spawn(.{}, DriverClientTest.run, .{&client_test});
    defer if (client_thread) |thread| {
        transport.stop();
        thread.join();
    };

    const oversized_response = try testing.allocator.alloc(u8, max_driver_response_bytes + 1);
    defer testing.allocator.free(oversized_response);
    for (0..2) |exchange_index| {
        const wake = window.pump(5000) orelse return error.TestExpectedEqual;
        try testing.expectEqual(Event.driver_wake, wake);
        var request = transport.takeRequest() orelse return error.TestExpectedEqual;
        defer request.deinit(testing.allocator);
        try testing.expectEqualStrings("request", request.bytes);
        if (exchange_index == 0) try testing.expectError(
            error.FrameTooLarge,
            transport.respond(request.token, oversized_response),
        );
        try transport.respond(request.token, response);
    }
    client_thread.?.join();
    client_thread = null;
    try testing.expect(client_test.ok.load(.acquire));
}

test "a nonsense platform scale resolves to the default instead of an empty surface" {
    // Each of these would otherwise reach `toPhysical` as a zero, a negative or a NaN and take the
    // drawable surface with it.
    try testing.expectEqual(Scale.default_factor, Scale.fromPlatform(0.0).factor);
    try testing.expectEqual(Scale.default_factor, Scale.fromPlatform(-2.0).factor);
    try testing.expectEqual(Scale.default_factor, Scale.fromPlatform(std.math.nan(f32)).factor);
    try testing.expectEqual(Scale.default_factor, Scale.fromPlatform(std.math.inf(f32)).factor);
    // Just under the floor is clamped up to the default, not kept at its reported value.
    try testing.expectEqual(Scale.default_factor, Scale.fromPlatform(Scale.min_factor / 2).factor);
    // Exactly at the floor is a real scale.
    try testing.expectEqual(Scale.min_factor, Scale.fromPlatform(Scale.min_factor).factor);
}

test "a fixed window scale wins over every display report" {
    const fixed = Scale.fromPlatform(1.5);

    try testing.expectEqual(fixed, selectScale(fixed, 1.0));
    try testing.expectEqual(fixed, selectScale(fixed, 2.0));
    try testing.expectEqual(fixed, selectScale(fixed, std.math.nan(f32)));
}

test "a window without a fixed scale follows normalised display reports" {
    try testing.expectEqual(@as(f32, 2.0), selectScale(null, 2.0).factor);
    try testing.expectEqual(Scale.default_factor, selectScale(null, 0.0).factor);
}

test "a usable scale is reported unchanged and doubles the surface in each axis" {
    const two_x = Scale.fromPlatform(2.0);
    try testing.expectEqual(2.0, two_x.factor);

    const logical = LogicalSize{ .width = 800, .height = 600 };
    const surface = SurfaceSize.fromLogical(logical, two_x);

    try testing.expectEqual(@as(u32, 1600), surface.width_px);
    try testing.expectEqual(@as(u32, 1200), surface.height_px);
}

test "a fractional scale follows the display instead of rounding back up" {
    const logical = LogicalSize{ .width = 601, .height = 601 };

    // At 1x the surface is exactly the logical size.
    const at_1x = SurfaceSize.fromLogical(logical, Scale.fromPlatform(1.0));
    try testing.expectEqual(logical.width, at_1x.width_px);
    try testing.expectEqual(logical.height, at_1x.height_px);

    // At 0.5x a fractional-scale display genuinely has half the pixels: 601 * 0.5 = 300.5 rounds
    // half up to 301, and is not clamped back to 601.
    const at_half = SurfaceSize.fromLogical(logical, Scale.fromPlatform(0.5));
    try testing.expectEqual(@as(u32, 301), at_half.width_px);
    try testing.expectEqual(@as(u32, 301), at_half.height_px);
}

test "a surface always has at least one pixel in each axis" {
    const clamped = SurfaceSize.init(0, 0);
    try testing.expectEqual(SurfaceSize.min_dimension, clamped.width_px);
    try testing.expectEqual(SurfaceSize.min_dimension, clamped.height_px);

    // A one-pixel window survives: clamping raises, it never truncates a real request away.
    const one = SurfaceSize.init(1, 1);
    try testing.expectEqual(@as(u32, 1), one.width_px);
    try testing.expectEqual(@as(u32, 1), one.height_px);

    // Even at the smallest legal scale, a window never becomes an empty surface.
    const tiny = SurfaceSize.fromLogical(
        .{ .width = 1, .height = 1 },
        Scale.fromPlatform(Scale.min_factor),
    );
    try testing.expectEqual(SurfaceSize.min_dimension, tiny.width_px);
    try testing.expectEqual(SurfaceSize.min_dimension, tiny.height_px);
}

test "a window state derives its surface from its size and scale, and nothing else" {
    const before = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    try testing.expectEqual(@as(u32, 800), before.surface.width_px);
    try testing.expectEqual(@as(u32, 600), before.surface.height_px);

    // The same window on a 2x display: the logical size is untouched, the surface doubles.
    const after = before.rescaled(Scale.fromPlatform(2.0));
    try testing.expectEqual(before.logical, after.logical);
    try testing.expectEqual(@as(u32, 1600), after.surface.width_px);
    try testing.expectEqual(@as(u32, 1200), after.surface.height_px);

    // A nonsensical scale resolves at the door, so the surface is never built from it.
    const nonsense = before.rescaled(Scale.fromPlatform(0.0));
    try testing.expectEqual(before.surface.width_px, nonsense.surface.width_px);
}

test "a resize event carries the size the window now has" {
    const window_id: sdl.SDL_WindowID = 7;
    const before = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    const now = State.init(.{ .width = 640, .height = 480 }, Scale.fromPlatform(1.0));

    const event = translate(
        windowEvent(window_id, sdl.SDL_EVENT_WINDOW_RESIZED),
        window_id,
        before,
        now,
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u32, 640), event.resized.logical.width);
    try testing.expectEqual(@as(u32, 480), event.resized.logical.height);
    try testing.expectEqual(@as(u32, 640), event.resized.surface.width_px);
    try testing.expectEqual(@as(u32, 480), event.resized.surface.height_px);

    // A pixel-size change is a resize too: on a display whose scale the window does not follow,
    // it is the only signal that the drawable moved.
    const pixels = translate(
        windowEvent(window_id, sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED),
        window_id,
        before,
        now,
    ) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 640), pixels.resized.logical.width);
}

test "a scale change carries both the scale it had and the one it has now" {
    const window_id: sdl.SDL_WindowID = 7;
    const before = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    const now = before.rescaled(Scale.fromPlatform(2.0));

    const event = translate(
        windowEvent(window_id, sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED),
        window_id,
        before,
        now,
    ) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(f32, 1.0), event.scale_changed.previous.factor);
    try testing.expectEqual(@as(f32, 2.0), event.scale_changed.state.scale.factor);
    try testing.expectEqual(@as(u32, 1600), event.scale_changed.state.surface.width_px);
}

test "focus, expose and close events reach the app in Conduit's own words" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));

    const cases = [_]struct { raw: SdlEventType, want: std.meta.Tag(Event) }{
        .{ .raw = @intCast(sdl.SDL_EVENT_WINDOW_FOCUS_GAINED), .want = .focused },
        .{ .raw = @intCast(sdl.SDL_EVENT_WINDOW_FOCUS_LOST), .want = .unfocused },
        .{ .raw = @intCast(sdl.SDL_EVENT_WINDOW_EXPOSED), .want = .exposed },
        // A window that has just been shown has never been drawn into.
        .{ .raw = @intCast(sdl.SDL_EVENT_WINDOW_SHOWN), .want = .exposed },
        .{ .raw = @intCast(sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED), .want = .close_requested },
    };
    for (cases) |case| {
        const event = translate(windowEvent(window_id, case.raw), window_id, state, state) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(case.want, std.meta.activeTag(event));
    }
}

test "quit is delivered, and an event for another window is not" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));

    var quit: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    quit.type = @intCast(sdl.SDL_EVENT_QUIT);
    // Quit belongs to the application, so it arrives whatever the window id is.
    try testing.expectEqual(Event.quit, translate(quit, window_id, state, state).?);

    // Another window's resize is not this app's business.
    try testing.expectEqual(@as(?Event, null), translate(
        windowEvent(@as(sdl.SDL_WindowID, 9), sdl.SDL_EVENT_WINDOW_RESIZED),
        window_id,
        state,
        state,
    ));
}
test "clipboard updates are translated without an SDL type escaping" {
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    raw.clipboard.type = @intCast(sdl.SDL_EVENT_CLIPBOARD_UPDATE);
    raw.clipboard.owner = true;

    const event = translate(raw, 7, state, state) orelse return error.TestUnexpectedResult;
    try testing.expect(event.clipboard_updated.owned);
}

test "a system theme change is an application event and the preference maps to three values" {
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    raw.common.type = @intCast(sdl.SDL_EVENT_SYSTEM_THEME_CHANGED);
    const event = translate(raw, 7, state, state) orelse return error.TestUnexpectedResult;
    try testing.expect(event == .system_theme_changed);

    try testing.expectEqual(SystemTheme.light, systemThemeFrom(sdl.SDL_SYSTEM_THEME_LIGHT));
    try testing.expectEqual(SystemTheme.dark, systemThemeFrom(sdl.SDL_SYSTEM_THEME_DARK));
    try testing.expectEqual(SystemTheme.unknown, systemThemeFrom(sdl.SDL_SYSTEM_THEME_UNKNOWN));
}

/// A keyboard event of Conduit's choosing, as SDL would deliver it.
fn keyEventFor(id: sdl.SDL_WindowID, kind: anytype, scancode: sdl.SDL_Scancode, key: sdl.SDL_Keycode, mod: sdl.SDL_Keymod) sdl.SDL_Event {
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    raw.key.type = @intCast(kind);
    raw.key.windowID = id;
    raw.key.scancode = scancode;
    raw.key.key = key;
    raw.key.mod = mod;
    raw.key.down = kind == sdl.SDL_EVENT_KEY_DOWN;
    return raw;
}

/// A text event of Conduit's choosing, as SDL would deliver it.
fn textEventFor(id: sdl.SDL_WindowID, kind: anytype, text: [:0]const u8, start: i32, length: i32) sdl.SDL_Event {
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    const c_text: [*:0]const u8 = text.ptr;
    switch (kind) {
        sdl.SDL_EVENT_TEXT_INPUT => {
            raw.text.type = @intCast(kind);
            raw.text.windowID = id;
            raw.text.text = c_text;
        },
        else => {
            raw.edit.type = @intCast(kind);
            raw.edit.windowID = id;
            raw.edit.text = c_text;
            raw.edit.start = start;
            raw.edit.length = length;
        },
    }
    return raw;
}

test "a key's character applies shift, caps lock and level modifiers but not commands" {
    // Every event below carries the unmodified keycode in `key`, which is what
    // SDL 3.4 sends for a real key event. With no keyboard initialised SDL
    // answers from its built-in US layout, the same table a US X11 keymap
    // gives, so the expectations are the US characters.
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    const Case = struct {
        scancode: sdl.SDL_Scancode,
        key: sdl.SDL_Keycode,
        mod: sdl.SDL_Keymod,
        codepoint: u21,
        unshifted: u21,
    };
    const cases = [_]Case{
        // Shift+h is H: the bug where the key path wrote `h` and the text
        // echo then committed `H` as well.
        .{ .scancode = sdl.SDL_SCANCODE_H, .key = 'h', .mod = sdl.SDL_KMOD_LSHIFT, .codepoint = 'H', .unshifted = 'h' },
        .{ .scancode = sdl.SDL_SCANCODE_W, .key = 'w', .mod = sdl.SDL_KMOD_RSHIFT, .codepoint = 'W', .unshifted = 'w' },
        // Shift on a symbol key is the layout's shifted symbol.
        .{ .scancode = sdl.SDL_SCANCODE_1, .key = '1', .mod = sdl.SDL_KMOD_LSHIFT, .codepoint = '!', .unshifted = '1' },
        // Caps Lock with no Shift is the upper-case letter.
        .{ .scancode = sdl.SDL_SCANCODE_A, .key = 'a', .mod = sdl.SDL_KMOD_CAPS, .codepoint = 'A', .unshifted = 'a' },
        // Ctrl, Alt and Super are commands, not shift levels: the encoder
        // decides what they do to the character.
        .{ .scancode = sdl.SDL_SCANCODE_A, .key = 'a', .mod = sdl.SDL_KMOD_LCTRL, .codepoint = 'a', .unshifted = 'a' },
        .{ .scancode = sdl.SDL_SCANCODE_X, .key = 'x', .mod = sdl.SDL_KMOD_LALT, .codepoint = 'x', .unshifted = 'x' },
        .{ .scancode = sdl.SDL_SCANCODE_V, .key = 'v', .mod = sdl.SDL_KMOD_LGUI, .codepoint = 'v', .unshifted = 'v' },
        // Ctrl+Shift keeps the shifted character and the plain one apart.
        .{ .scancode = sdl.SDL_SCANCODE_A, .key = 'a', .mod = sdl.SDL_KMOD_LCTRL | sdl.SDL_KMOD_LSHIFT, .codepoint = 'A', .unshifted = 'a' },
    };
    for (cases) |case| {
        const event = translate(keyEventFor(
            window_id,
            sdl.SDL_EVENT_KEY_DOWN,
            case.scancode,
            case.key,
            case.mod,
        ), window_id, state, state).?;
        try testing.expectEqual(case.codepoint, event.key.codepoint);
        try testing.expectEqual(case.unshifted, event.key.unshifted_codepoint);
    }

    // A shifted press and its release after Shift came up are the same key:
    // the unshifted character agrees even though the character does not.
    const press = translate(keyEventFor(window_id, sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_SCANCODE_Y, 'y', sdl.SDL_KMOD_LSHIFT), window_id, state, state).?;
    const release = translate(keyEventFor(window_id, sdl.SDL_EVENT_KEY_UP, sdl.SDL_SCANCODE_Y, 'y', 0), window_id, state, state).?;
    try testing.expectEqual(@as(u21, 'Y'), press.key.codepoint);
    try testing.expectEqual(@as(u21, 'y'), release.key.codepoint);
    try testing.expectEqual(press.key.unshifted_codepoint, release.key.unshifted_codepoint);
}

test "macOS Option as Alt follows the configured side" {
    const lalt: sdl.SDL_Keymod = sdl.SDL_KMOD_LALT;
    const ralt: sdl.SDL_Keymod = sdl.SDL_KMOD_RALT;
    const both: sdl.SDL_Keymod = lalt | ralt;
    const cases = [_]struct { mode: OptionAsAlt, keymod: sdl.SDL_Keymod, alt: bool }{
        .{ .mode = .none, .keymod = lalt, .alt = false },
        .{ .mode = .none, .keymod = ralt, .alt = false },
        .{ .mode = .both, .keymod = lalt, .alt = true },
        .{ .mode = .both, .keymod = ralt, .alt = true },
        .{ .mode = .left, .keymod = lalt, .alt = true },
        .{ .mode = .left, .keymod = ralt, .alt = false },
        .{ .mode = .right, .keymod = lalt, .alt = false },
        .{ .mode = .right, .keymod = ralt, .alt = true },
        .{ .mode = .left, .keymod = both, .alt = true },
        .{ .mode = .right, .keymod = both, .alt = true },
        .{ .mode = .both, .keymod = 0, .alt = false },
    };
    for (cases) |case| try testing.expectEqual(case.alt, optionActsAsAlt(case.keymod, case.mode));
    try testing.expectEqualStrings("none", OptionAsAlt.none.sdlHint());
    try testing.expectEqualStrings("only_left", OptionAsAlt.left.sdlHint());
    try testing.expectEqualStrings("only_right", OptionAsAlt.right.sdlHint());
    try testing.expectEqualStrings("both", OptionAsAlt.both.sdlHint());
}

test "macOS Option composes only on a character key with no command modifier on a non-Alt side" {
    const option_x: KeyEvent = .{ .action = .press, .mods = .{ .alt = true }, .codepoint = 'x', .unshifted_codepoint = 'x' };
    // Option+x: the text system's character, unless that Option is Alt.
    try testing.expect(optionComposes(option_x, sdl.SDL_KMOD_LALT, .none));
    try testing.expect(optionComposes(option_x, sdl.SDL_KMOD_LALT, .right));
    try testing.expect(!optionComposes(option_x, sdl.SDL_KMOD_LALT, .left));
    try testing.expect(!optionComposes(option_x, sdl.SDL_KMOD_RALT, .both));
    // Option+Shift+x is still a composed character.
    var shifted = option_x;
    shifted.mods.shift = true;
    try testing.expect(optionComposes(shifted, sdl.SDL_KMOD_LALT | sdl.SDL_KMOD_LSHIFT, .none));
    // Option+Left is a modified named key, and Command or Control make a chord.
    const option_left: KeyEvent = .{ .action = .press, .key = .left, .mods = .{ .alt = true } };
    try testing.expect(!optionComposes(option_left, sdl.SDL_KMOD_LALT, .none));
    var command = option_x;
    command.mods.super = true;
    try testing.expect(!optionComposes(command, sdl.SDL_KMOD_LALT | sdl.SDL_KMOD_LGUI, .none));
    var control = option_x;
    control.mods.ctrl = true;
    try testing.expect(!optionComposes(control, sdl.SDL_KMOD_LALT | sdl.SDL_KMOD_LCTRL, .none));
    // No Option, or a key with no character, composes nothing.
    try testing.expect(!optionComposes(.{ .action = .press, .codepoint = 'x', .unshifted_codepoint = 'x' }, 0, .none));
    try testing.expect(!optionComposes(.{ .action = .press, .mods = .{ .alt = true } }, sdl.SDL_KMOD_LALT, .none));
}

test "a translated key reports Option composition only on macOS" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));
    const raw = keyEventFor(window_id, sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_SCANCODE_X, 'x', sdl.SDL_KMOD_LALT);
    const composing = translateWithDriverEvents(raw, window_id, state, state, null, .none).?;
    const alt = translateWithDriverEvents(raw, window_id, state, state, null, .both).?;
    // The modifier is reported either way: bindings and UI keys still see Option.
    try testing.expect(composing.key.mods.alt and alt.key.mods.alt);
    try testing.expectEqual(builtin.os.tag == .macos, composing.key.option_composes);
    try testing.expect(!alt.key.option_composes);
}

test "a key arrives with its character, its unshifted character and its named key" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));

    // Plain 'a': the character the layout produced, and the same character
    // unshifted because nothing was holding shift down.
    const plain = translate(keyEventFor(
        window_id,
        sdl.SDL_EVENT_KEY_DOWN,
        sdl.SDL_SCANCODE_A,
        'a',
        0,
    ), window_id, state, state).?;
    try testing.expectEqual(KeyAction.press, plain.key.action);
    try testing.expectEqual(Key.unidentified, plain.key.key);
    try testing.expectEqual(@as(u21, 'a'), plain.key.codepoint);
    try testing.expectEqual(@as(u21, 'a'), plain.key.unshifted_codepoint);
    try testing.expectEqual(Mods{}, plain.key.mods);

    // Shift+a: the character is upper case, the unshifted one is not, and the
    // shift is reported. The pair is what lets a terminal tell ctrl+a from
    // ctrl+shift+a. SDL 3.4 reports the unmodified keycode `a` on the event
    // itself, so the upper case has to come from the layout, not from `key`.
    const shifted = translate(keyEventFor(
        window_id,
        sdl.SDL_EVENT_KEY_DOWN,
        sdl.SDL_SCANCODE_A,
        'a',
        sdl.SDL_KMOD_SHIFT,
    ), window_id, state, state).?;
    try testing.expectEqual(@as(u21, 'A'), shifted.key.codepoint);
    try testing.expectEqual(@as(u21, 'a'), shifted.key.unshifted_codepoint);
    try testing.expect(shifted.key.mods.shift);

    // The function row is layout-independent, and comes with no character.
    const f5 = translate(keyEventFor(
        window_id,
        sdl.SDL_EVENT_KEY_DOWN,
        sdl.SDL_SCANCODE_F5,
        0,
        0,
    ), window_id, state, state).?;
    try testing.expectEqual(Key.f5, f5.key.key);
    try testing.expectEqual(@as(u21, 0), f5.key.codepoint);
    try testing.expectEqual(@as(u21, 0), f5.key.unshifted_codepoint);

    // A modifier key is named by SDL above the Unicode range and must not
    // arrive as a character: a codepoint field holding 0x40000000 is not a
    // codepoint.
    const ctrl = translate(keyEventFor(
        window_id,
        sdl.SDL_EVENT_KEY_DOWN,
        sdl.SDL_SCANCODE_LCTRL,
        0x4000_0000,
        sdl.SDL_KMOD_LCTRL,
    ), window_id, state, state).?;
    try testing.expectEqual(@as(u21, 0), ctrl.key.codepoint);
    try testing.expectEqual(Key.unidentified, ctrl.key.key);

    // Up and down are different actions, and a repeat is neither of them.
    const released = translate(keyEventFor(
        window_id,
        sdl.SDL_EVENT_KEY_UP,
        sdl.SDL_SCANCODE_A,
        'a',
        0,
    ), window_id, state, state).?;
    try testing.expectEqual(KeyAction.release, released.key.action);

    var repeating = keyEventFor(window_id, sdl.SDL_EVENT_KEY_DOWN, sdl.SDL_SCANCODE_A, 'a', 0);
    repeating.key.repeat = true;
    try testing.expectEqual(
        KeyAction.repeat,
        translate(repeating, window_id, state, state).?.key.action,
    );

    // Another window's keystroke is not this app's business.
    try testing.expectEqual(@as(?Event, null), translate(keyEventFor(
        @as(sdl.SDL_WindowID, 9),
        sdl.SDL_EVENT_KEY_DOWN,
        sdl.SDL_SCANCODE_A,
        'a',
        0,
    ), window_id, state, state));
}

test "committed text and a composition both arrive, with the composition's offsets made safe" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));

    // Text committed by the keyboard or by an input method: exactly the bytes,
    // borrowed.
    const typed = translate(textEventFor(
        window_id,
        sdl.SDL_EVENT_TEXT_INPUT,
        "hello",
        0,
        0,
    ), window_id, state, state).?;
    try testing.expectEqualStrings("hello", typed.text_input);

    // A preedit with a selection inside it: the whole text plus where the
    // selection is. The pair is self-consistent — "konnichiha" is ten bytes and
    // the last four of them start at 6 — because a length past the end of the
    // text is clamped rather than believed, and a test that relied on that
    // clamp here would be testing the clamp twice instead of the selection.
    const composing = translate(textEventFor(
        window_id,
        sdl.SDL_EVENT_TEXT_EDITING,
        "konnichiha",
        6,
        4,
    ), window_id, state, state).?;
    try testing.expectEqualStrings("konnichiha", composing.text_editing.text);
    try testing.expectEqual(@as(u32, 6), composing.text_editing.start);
    try testing.expectEqual(@as(u32, 4), composing.text_editing.length);

    // An input method reporting a range its own text does not contain is
    // making a number up, and the number is clamped rather than believed:
    // the alternative is a slice of whatever follows it in memory.
    const lying = translate(textEventFor(
        window_id,
        sdl.SDL_EVENT_TEXT_EDITING,
        "にほん",
        2,
        900,
    ), window_id, state, state).?;
    try testing.expectEqualStrings("にほん", lying.text_editing.text);
    try testing.expectEqual(@as(u32, 2), lying.text_editing.start);
    // "にほん" is three three-byte characters, so it is nine bytes, and nine
    // bytes from offset 2 leaves seven selectable — not four: the old comment
    // counted bytes as though each character were two.
    try testing.expectEqual(@as(u32, 7), lying.text_editing.length);

    // "No selection" is -1 on both fields, and means the caret, not the end of
    // the text.
    const caret = translate(textEventFor(
        window_id,
        sdl.SDL_EVENT_TEXT_EDITING,
        "abc",
        -1,
        -1,
    ), window_id, state, state).?;
    try testing.expectEqual(@as(u32, 0), caret.text_editing.start);
    try testing.expectEqual(@as(u32, 0), caret.text_editing.length);

    // A composition that has ended arrives as empty text, which is what makes
    // `Composition.isComposing` false again.
    const ended = translate(textEventFor(
        window_id,
        sdl.SDL_EVENT_TEXT_EDITING,
        "",
        0,
        0,
    ), window_id, state, state).?;
    try testing.expectEqualStrings("", ended.text_editing.text);

    // Another window's text is not this app's business either.
    try testing.expectEqual(@as(?Event, null), translate(textEventFor(
        @as(sdl.SDL_WindowID, 9),
        sdl.SDL_EVENT_TEXT_INPUT,
        "hello",
        0,
        0,
    ), window_id, state, state));
}

test "a candidate list is copied in, bounded, and its selection made safe" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));

    // The three candidates an input method offered, with the second in focus.
    // The array has to hold exactly as many pointers as the count says: SDL
    // frees it as soon as the event has been read, and a count larger than the
    // array behind it is not a longer candidate list, it is a read past the end
    // of one. The overflow case below builds a real twenty-entry array for the
    // same reason — the old fixture claimed twenty candidates behind three
    // pointers, and reading the difference is what made this test abort.
    const one: [:0]const u8 = "one";
    const two: [:0]const u8 = "two";
    const three: [:0]const u8 = "three";
    var list = [_][*:0]const u8{ one.ptr, two.ptr, three.ptr };
    var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
    raw.edit_candidates.type = @intCast(sdl.SDL_EVENT_TEXT_EDITING_CANDIDATES);
    raw.edit_candidates.windowID = window_id;
    raw.edit_candidates.candidates = &list;
    raw.edit_candidates.num_candidates = list.len;
    raw.edit_candidates.selected_candidate = 1;

    const candidates = translate(raw, window_id, state, state).?.candidates;
    try testing.expectEqual(@as(usize, 3), candidates.len());
    try testing.expectEqualStrings("one", candidates.get(0).?);
    try testing.expectEqualStrings("two", candidates.get(1).?);
    try testing.expectEqualStrings("three", candidates.get(2).?);
    try testing.expectEqual(@as(?[]const u8, null), candidates.get(3));
    try testing.expectEqualStrings("two", candidates.current().?);
    try testing.expect(!candidates.truncated);

    // An index the list does not have is no selection, and -1 is an input
    // method saying it has not chosen one.
    raw.edit_candidates.selected_candidate = 99;
    const out_of_range = translate(raw, window_id, state, state).?.candidates;
    try testing.expectEqual(@as(?u8, null), out_of_range.selected);
    try testing.expectEqual(@as(?[]const u8, null), out_of_range.current());

    raw.edit_candidates.selected_candidate = -1;
    const unchosen = translate(raw, window_id, state, state).?.candidates;
    try testing.expectEqual(@as(?u8, null), unchosen.selected);

    // More candidates than the value can hold are dropped, and the count says
    // so rather than the list quietly looking complete. The array behind them
    // is twenty real entries, because that is the event SDL would deliver: the
    // count is a promise about the array, not a number to read past.
    var many_text: [20][:0]u8 = undefined;
    var many: [20][*:0]const u8 = undefined;
    for (&many_text, 0..) |*slot, index| {
        slot.* = try std.fmt.allocPrintSentinel(testing.allocator, "candidate-{d}", .{index}, 0);
        many[index] = slot.ptr;
    }
    // One defer for the whole array, not one inside the loop: `defer` in a
    // loop body runs at the end of that body, which would free every string
    // before the event that points at them was ever read.
    defer for (many_text) |text| testing.allocator.free(text);
    raw.edit_candidates.candidates = &many;
    raw.edit_candidates.num_candidates = many.len;
    raw.edit_candidates.selected_candidate = 0;
    const too_many = translate(raw, window_id, state, state).?.candidates;
    try testing.expectEqual(Candidates.capacity, too_many.len());
    try testing.expect(too_many.truncated);

    // A count of zero, or a null array, is an input method with nothing to say.
    raw.edit_candidates.num_candidates = 0;
    try testing.expectEqual(
        @as(usize, 0),
        translate(raw, window_id, state, state).?.candidates.len(),
    );
    raw.edit_candidates.num_candidates = 3;
    raw.edit_candidates.candidates = null;
    try testing.expectEqual(
        @as(usize, 0),
        translate(raw, window_id, state, state).?.candidates.len(),
    );
}

test "a candidate longer than the bound is cut on a codepoint boundary" {
    // Longer than `max_length` in total, and the cut has to land between
    // codepoints: half a codepoint is not text.
    var long: [Candidates.max_length + 8]u8 = undefined;
    @memset(&long, 'a');
    const candidates = Candidates.candidates(&.{long[0..]}, 0, false);
    try testing.expect(candidates.truncated);
    try testing.expectEqual(Candidates.max_length, candidates.get(0).?.len);

    // The same, where the cut would otherwise land inside a three-byte
    // character. Nine bytes of 日本語 is nowhere near the bound, so it is
    // nothing to cut: thirty copies of it are ninety bytes, and byte 64 of
    // that is the second byte of a character, so what survives is 63 bytes —
    // twenty-one whole characters, the most that fits.
    var wide: [90]u8 = undefined;
    const word: []const u8 = "\u{65e5}\u{672c}\u{8a9e}";
    for (0..30) |index| @memcpy(wide[index * 3 ..][0..3], word[0..3]);
    const cut = Candidates.candidates(&.{wide[0..]}, 0, false);
    try testing.expect(cut.truncated);
    try testing.expectEqual(Candidates.max_length - 1, cut.get(0).?.len);
    // Whole text is what "cut on a codepoint boundary" has to mean: a valid
    // UTF-8 string, not a prefix that merely happens to end on a byte the
    // next character does not start with. (Checking that no byte is a
    // continuation byte would only ever hold for ASCII.)
    try testing.expect(std.unicode.utf8ValidateSlice(cut.get(0).?));
}

test "a cell becomes the rectangle an input method is told about" {
    const cell = LogicalSize{ .width = 10, .height = 20 };

    // The caret at the start of the cell: the rectangle starts at the cell.
    try testing.expectEqual(LogicalRect{ .x = 30, .y = 40, .width = 10, .height = 20 }, LogicalRect.forCell(3, 2, cell, 0));
    // Part-way through the cell: the rectangle follows the caret to the right.
    try testing.expectEqual(LogicalRect{ .x = 32, .y = 40, .width = 10, .height = 20 }, LogicalRect.forCell(3, 2, cell, 2));
    // A caret past the end of the cell is clamped to it, so a candidate window
    // is never placed outside the text it belongs to.
    try testing.expectEqual(LogicalRect{ .x = 40, .y = 40, .width = 10, .height = 20 }, LogicalRect.forCell(3, 2, cell, 999));
}

test "input events are translated here, and the families Conduit does not use are dropped" {
    const window_id: sdl.SDL_WindowID = 7;
    const state = State.init(.{ .width = 800, .height = 600 }, Scale.fromPlatform(1.0));

    // Everything `input` needs arrives in Conduit's own words, from the same
    // pump as the window events: the four input tags are part of `Event`, so a
    // caller switching over it is told at compile time that a keystroke exists
    // rather than finding out at runtime that one went somewhere else.
    inline for (.{ "key", "text_input", "text_editing", "candidates" }) |name| {
        try testing.expect(@hasField(Event, name));
    }

    // Pointer events joined the union with TASK-14, so the mouse is no longer a
    // family that is dropped. A motion for this window arrives as a pointer
    // motion and nothing else.
    inline for (.{ "mouse_button", "mouse_motion" }) |name| {
        try testing.expect(@hasField(Event, name));
    }
    {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.motion.type = @intCast(sdl.SDL_EVENT_MOUSE_MOTION);
        raw.motion.windowID = window_id;
        raw.motion.x = 4;
        raw.motion.y = 5;
        const event = translate(raw, window_id, state, state).?;
        try testing.expectEqual(@as(f32, 4), event.mouse_motion.x);
        try testing.expectEqual(@as(f32, 5), event.mouse_motion.y);
    }

    // The families that are still nobody's business are still dropped rather
    // than half-guessed at: joystick and touch have no owner yet.
    const dropped = [_]SdlEventType{
        @intCast(sdl.SDL_EVENT_JOYSTICK_AXIS_MOTION),
        @intCast(sdl.SDL_EVENT_FINGER_DOWN),
    };
    for (dropped) |kind| {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.type = kind;
        try testing.expectEqual(@as(?Event, null), translate(raw, window_id, state, state));
    }

    // A motion for a window that is not this one is not this terminal's, and a
    // pointer that has left every window is reported as FLT_MAX with window id 0
    // — neither may become a cell.
    {
        var raw: sdl.SDL_Event = std.mem.zeroes(sdl.SDL_Event);
        raw.motion.type = @intCast(sdl.SDL_EVENT_MOUSE_MOTION);
        raw.motion.windowID = 9;
        try testing.expectEqual(@as(?Event, null), translate(raw, window_id, state, state));

        raw.motion.windowID = 0;
        raw.motion.x = std.math.floatMax(f32);
        raw.motion.y = std.math.floatMax(f32);
        try testing.expectEqual(@as(?Event, null), translate(raw, window_id, state, state));
    }
}

test "the events that move the surface are the ones that ask the OS again" {
    // If this list and `translate`'s payload-bearing list disagree, a resize arrives with a stale
    // surface. They are separate functions, so they are checked against each other here.
    try testing.expect(changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_RESIZED)));
    try testing.expect(changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED)));
    try testing.expect(changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_CHANGED)));
    try testing.expect(changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED)));

    // Focus and close say nothing about size, and re-reading the window for them would be a round
    // trip to the window system on every click.
    try testing.expect(!changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_FOCUS_GAINED)));
    try testing.expect(!changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_CLOSE_REQUESTED)));
    try testing.expect(!changesGeometry(@intCast(sdl.SDL_EVENT_WINDOW_EXPOSED)));
}

test "clipboard text round trips through SDL's isolated dummy backend" {
    if (!primary_selection_supported) return error.SkipZigTest;
    // Never touch a clipboard belonging to an already-running display. The
    // dummy backend owns only this process's fixed fixtures.
    if (sdl.SDL_GetCurrentVideoDriver() != null) return error.SkipZigTest;
    if (!sdl.SDL_SetHint(sdl.SDL_HINT_VIDEO_DRIVER, "dummy")) return error.SkipZigTest;
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return error.SkipZigTest;
    defer sdl.SDL_QuitSubSystem(sdl.SDL_INIT_VIDEO);

    try setClipboardText(testing.allocator, "conduit clipboard fixture");
    try testing.expect(hasClipboardText());
    const standard = try getClipboardText(testing.allocator);
    defer testing.allocator.free(standard);
    try testing.expectEqualStrings("conduit clipboard fixture", standard);

    try setPrimarySelectionText(testing.allocator, "conduit primary fixture");
    try testing.expect(hasPrimarySelectionText());
    const primary = try getPrimarySelectionText(testing.allocator);
    defer testing.allocator.free(primary);
    try testing.expectEqualStrings("conduit primary fixture", primary);
}

test "clipboard payloads are bounded and validated before SDL sees them" {
    try testing.expectError(error.InvalidText, setClipboardText(testing.allocator, "nul\x00tail"));
    try testing.expectError(error.InvalidText, setPrimarySelectionText(testing.allocator, "bad\xffutf8"));

    const too_large = try testing.allocator.alloc(u8, max_clipboard_bytes + 1);
    defer testing.allocator.free(too_large);
    @memset(too_large, 'x');
    try testing.expectError(error.PayloadTooLarge, setClipboardText(testing.allocator, too_large));
}

test "notification text is refused when over its bound or carrying controls" {
    try std.testing.expectError(error.InvalidText, validateNotifyText("a\x07b", 16));
    try std.testing.expectError(error.InvalidText, validateNotifyText("\xff", 16));
    try std.testing.expectError(error.InvalidText, validateNotifyText("x" ** 17, 16));
    try validateNotifyText("Needs approval \xe2\x9c\x93", 32);
}

test "foreign windows are hosted only under X11 and refused elsewhere" {
    try std.testing.expect(!embedSupported(null));
    try std.testing.expect(!embedSupported("wayland"));
    try std.testing.expect(!embedSupported("cocoa"));
    try std.testing.expect(!embedSupported("windows"));
    try std.testing.expect(!embedSupported("offscreen"));
    try std.testing.expectEqual(builtin.os.tag == .linux and builtin.link_libc, embedSupported("x11"));
    // An empty match never picks an arbitrary window.
    try std.testing.expectError(if (x11_embedding_built) error.NotFound else error.Unsupported, embedIntoX11Checked(0, .{}, .{ .x = 0, .y = 0, .width = 1, .height = 1 }));
}

/// `embedIntoX11` behind the build gate, so the Unsupported path is testable on every OS.
fn embedIntoX11Checked(parent: c_ulong, match: ForeignWindowMatch, rect: PixelRect) EmbedError!EmbeddedWindow {
    if (comptime !x11_embedding_built) return error.Unsupported;
    return embedIntoX11(parent, match, rect);
}

test "X11: a real client window is reparented into a container, moved, hidden, and given back" {
    if (comptime !x11_embedding_built) return error.SkipZigTest;
    const api = X11.get() orelse return error.SkipZigTest;
    const display = api.XOpenDisplay(null) orelse return error.SkipZigTest; // no X server
    defer _ = api.XCloseDisplay(display);
    const io = std.testing.io;

    // A top-level stand-in for Conduit's SDL window.
    const root = api.XDefaultRootWindow(display);
    const host = api.XCreateSimpleWindow(display, root, 0, 0, 400, 300, 0, 0, 0);
    _ = api.XMapWindow(display, host);
    _ = api.XSync(display, 0);
    defer {
        _ = api.XDestroyWindow(display, host);
        _ = api.XSync(display, 0);
    }

    var child = std.process.spawn(io, .{
        .argv = &.{ "xlogo", "-geometry", "120x90+500+10" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.SkipZigTest; // xlogo is not installed
    defer child.kill(io);

    // xlogo sets WM_CLASS (xlogo, XLogo); poll until it has mapped, bounded.
    const match: ForeignWindowMatch = .{ .class = "XLogo" };
    var embedded: EmbeddedWindow = for (0..200) |_| {
        if (embedIntoX11(host, match, .{ .x = 10, .y = 20, .width = 200, .height = 150 })) |hosted| {
            break hosted;
        } else |err| switch (err) {
            error.NotFound => std.Io.Clock.Duration.sleep(.{ .raw = .fromMilliseconds(25), .clock = .awake }, io) catch {},
            else => return err,
        }
    } else return error.TestUnexpectedResult;
    var released = false;
    defer if (!released) unembedX11(&embedded);

    // The client now lives in Conduit's container, which is a child of the host.
    try std.testing.expectEqual(@as(?c_ulong, embedded.container), api.parentOf(display, embedded.client));
    try std.testing.expectEqual(@as(?c_ulong, host), api.parentOf(display, embedded.container));
    // A second search skips nothing hosted already but finds the same client by class.
    try std.testing.expectEqual(@as(?c_ulong, embedded.client), api.find(display, root, match, 0));
    try std.testing.expectEqual(@as(?c_ulong, null), api.find(display, root, .{ .class = "NoSuchClass" }, 0));

    try moveEmbeddedX11(&embedded, .{ .x = 5, .y = 6, .width = 300, .height = 200 });
    try showEmbeddedX11(&embedded, false);
    try std.testing.expect(!embedded.visible);
    try showEmbeddedX11(&embedded, true);

    const client = embedded.client;
    unembedX11(&embedded);
    released = true;
    // Given back to the desktop, not destroyed.
    try std.testing.expectEqual(@as(?c_ulong, root), api.parentOf(display, client));
}

const LocalEchoServer = struct {
    listener: *LocalSocketListener,
    streams: [4]?LocalStream = @splat(null),

    /// Accept until cancelled, answering one line per connection and keeping each open, so the
    /// clients hold several instances of the pipe at once.
    fn run(self: *LocalEchoServer) void {
        const io = testing.io;
        for (&self.streams) |*slot| {
            const stream = self.listener.accept(io) catch return;
            slot.* = stream;
            var buffer: [64]u8 = undefined;
            var used: usize = 0;
            while (std.mem.indexOfScalar(u8, buffer[0..used], '\n') == null and used < buffer.len) {
                const count = stream.read(io, buffer[used..]) catch return;
                if (count == 0) return;
                used += count;
            }
            stream.writeAll(io, buffer[0..used]) catch return;
        }
    }
};

test "the local listener serves concurrent clients and, on Windows, refuses anonymous and remote ones" {
    if (builtin.os.tag != .windows and builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const io = testing.io;
    var random: [8]u8 = undefined;
    io.random(&random);
    var name_buffer: [128]u8 = undefined;
    const endpoint = if (builtin.os.tag == .windows)
        try std.fmt.bufPrint(&name_buffer, "\\\\.\\pipe\\conduit-listener-test-{x}", .{&random})
    else
        try std.fmt.bufPrint(&name_buffer, "/tmp/conduit-lt-{x}/l.sock", .{&random});
    if (builtin.os.tag != .windows) {
        try std.Io.Dir.cwd().createDir(io, std.fs.path.dirname(endpoint).?, .fromMode(0o700));
    }
    // Best-effort cleanup of a test directory; a leftover only wastes /tmp space.
    defer if (builtin.os.tag != .windows) std.Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(endpoint).?) catch {};

    var listener = try LocalSocketListener.listen(io, endpoint);
    defer listener.deinit(io, endpoint);
    if (builtin.os.tag == .windows) {
        // The first instance owns the name: a second listener cannot take it over.
        try testing.expectError(error.EndpointOccupied, LocalSocketListener.listen(io, endpoint));
    }
    var server: LocalEchoServer = .{ .listener = &listener };
    const thread = try std.Thread.spawn(.{}, LocalEchoServer.run, .{&server});
    var joined = false;
    defer if (!joined) stopEchoServer(&listener, endpoint, thread);
    defer for (server.streams) |slot| if (slot) |stream| stream.close(io);

    // Two clients stay connected at once.
    var first = try DriverClient.connect(endpoint);
    defer first.deinit();
    var second = try DriverClient.connect(endpoint);
    defer second.deinit();
    const first_reply = try first.exchange(testing.allocator, "one");
    defer testing.allocator.free(first_reply);
    const second_reply = try second.exchange(testing.allocator, "two");
    defer testing.allocator.free(second_reply);
    try testing.expectEqualStrings("one", first_reply);
    try testing.expectEqualStrings("two", second_reply);

    if (builtin.os.tag == .windows) {
        // Another user: an anonymous token is not the current logon SID, so the pipe's
        // descriptor refuses it while an instance is waiting.
        if (WindowsDriver.ImpersonateAnonymousToken(WindowsDriver.GetCurrentThread()) == .FALSE) return error.TestUnexpectedResult;
        const anonymous = WindowsDriver.openClient(endpoint);
        if (WindowsDriver.RevertToSelf() == .FALSE) return error.TestUnexpectedResult;
        if (anonymous) |handle| {
            std.os.windows.CloseHandle(handle);
            return error.TestUnexpectedResult;
        } else |_| {}
        // A remote client: the same pipe through the network redirector is rejected.
        var remote_buffer: [160]u8 = undefined;
        const remote = try std.fmt.bufPrint(&remote_buffer, "\\\\localhost\\pipe\\{s}", .{endpoint["\\\\.\\pipe\\".len..]});
        if (WindowsDriver.openClient(remote)) |handle| {
            std.os.windows.CloseHandle(handle);
            return error.TestUnexpectedResult;
        } else |_| {}
        // The current user still connects after both refusals.
        var third = try DriverClient.connect(endpoint);
        defer third.deinit();
        const third_reply = try third.exchange(testing.allocator, "three");
        defer testing.allocator.free(third_reply);
        try testing.expectEqualStrings("three", third_reply);
    }

    stopEchoServer(&listener, endpoint, thread);
    joined = true;
}

fn stopEchoServer(listener: *LocalSocketListener, endpoint: []const u8, thread: std.Thread) void {
    listener.cancelAccept(testing.io);
    // Darwin's shutdown does not wake a blocked accept; one connection does.
    if (builtin.os.tag != .linux and builtin.os.tag != .windows) {
        var waker = DriverClient.connect(endpoint) catch null;
        if (waker) |*client| client.deinit();
    }
    thread.join();
}
