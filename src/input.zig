//! Conduit's input module: raw events in, named intent out.
//!
//! `input` owns turning raw events into intent — keyboard encoding and IME,
//! mouse reporting and text selection gestures, the action registry,
//! keybindings and routing. It takes key and mouse encoding from `term` and
//! reaches a focused element through `ui`'s tree.
//!
//! It never swallows a key Conduit did not bind: an unbound key reaches the
//! terminal unmodified, and ctrl+c with no selection is always SIGINT (P10,
//! invariant 8). It never exposes a command that is not in the registry, and it
//! never special-cases a harness. It may depend on `ui` for hit testing and
//! focus, `term` for key and mouse encoding and terminal writes, and `platform`
//! for raw events and the clipboard.
//!
//! Routing allocates nothing. An event is a value, and the allocator that will
//! own composition state, IME state and encoding buffers arrives as a
//! parameter. The one allocating operation is `buildBindings` (TASK-37), which
//! builds a configured binding table into its own arena outside the event path.
//!
//! TASK-20 adds the registry and binding layer over the TASK-12 translation:
//! registered actions are the only commands dispatch can invoke, bindings use
//! the unshifted key identity, and an unbound route returns the translated
//! terminal press without rebuilding it.
//!
//! ## Two layers, kept apart on purpose
//!
//! `Modifiers`, `Key` and `KeyEvent` are *intent*: what a binding matches
//! against, layout-independent, with no bytes in them. `translate` is
//! *encoding*: the `term.KeyPress` a terminal turns into bytes. They are
//! separate types because they have different lifetimes — a binding matches
//! every key, and the encoder is only consulted for the keys that reached the
//! terminal — and because the protocol layer changes (the Kitty keyboard
//! protocol changed what a key press means twice) while the intent layer does
//! not.
//!
//! ## IME: the preedit is display-only, and that is structural
//!
//! An input method composes text the user has not committed. That text belongs
//! on the screen and nowhere else, and the guarantee is not a rule this module
//! has to remember: `translate` sets `KeyPress.composing` while a composition
//! is live, and the encoder emits *nothing at all* for a composing press. A
//! preedit cannot reach the child because there is no path from one to the
//! other. What is left to get right here is the state machine — what the
//! preedit says, which candidate is in focus, and which text was committed.

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform");
const term = @import("term");
const ui = @import("ui");

/// The log scope for input diagnostics.
pub const log = std.log.scoped(.input);

/// The modifiers that were down when a key was pressed.
///
/// The lock keys are read from the keyboard but they are state, not intent: a
/// user who leaves caps lock on is still typing the letters the keyboard
/// reports, and no binding is ever "ctrl + caps lock". `normalized` is what the
/// registry and the terminal encoder compare against, and `isCommand` is what
/// separates a shortcut from text.
pub const Modifiers = packed struct(u6) {
    /// Control. With nothing selected in the terminal, ctrl+c is SIGINT.
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

    /// The modifiers that are intent, with the lock keys dropped. Idempotent,
    /// so it can be applied wherever a normalised set is required without
    /// having to know whether it already has been.
    pub fn normalized(self: Modifiers) Modifiers {
        var out = self;
        out.caps_lock = false;
        out.num_lock = false;
        return out;
    }

    /// Whether the modifiers change what the key means. Ctrl, alt and super do;
    /// shift does not, because the character reported with shift held is
    /// already the shifted character.
    pub fn isCommand(self: Modifiers) bool {
        return self.ctrl or self.alt or self.super;
    }
};

/// The keys a terminal UI has to tell apart that are not characters — the ones a
/// terminal program binds by escape sequence, and the function row.
pub const Named = enum {
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

/// A key: either a character key or one of the named keys.
///
/// A control character is not a key of its own — ctrl+c is the letter c with the
/// ctrl modifier, and a terminal program receives it as such — so a codepoint
/// that decodes to a control is a decoding failure the caller must handle. It is
/// never an `unreachable`: these codepoints come from the windowing system, and
/// malformed input must not crash the app.
pub const Key = union(enum) {
    /// A printable Unicode codepoint.
    character: u21,
    /// A key with no printable form of its own.
    named: Named,

    /// Why a codepoint is not a character key.
    pub const Error = error{ControlCharacter};

    /// The character key for `codepoint`, or `error.ControlCharacter` for the
    /// C0 controls, DEL and the C1 controls. C1 is excluded because a platform
    /// reports those as an escape followed by a byte in `0x40..0x5f`, so a bare
    /// C1 codepoint means the escape was decoded twice.
    pub fn fromCharacter(codepoint: u21) Error!Key {
        const is_control = codepoint < 0x20 or
            codepoint == 0x7f or
            (codepoint >= 0x80 and codepoint < 0xa0);
        if (is_control) return error.ControlCharacter;
        return .{ .character = codepoint };
    }
};

/// A key press as it arrives, before any binding is consulted.
pub const KeyEvent = struct {
    /// The key that was pressed.
    key: Key,
    /// The modifiers that were down with it, locks included.
    modifiers: Modifiers,

    /// The text this event inserts, or `null` when it inserts none: a modified
    /// character key is a command rather than text, and a named key is not text
    /// at all. Shift does not stop text — the keyboard has applied it to the
    /// character already — and neither do the lock keys, which is why the
    /// comparison is made against the normalised modifiers.
    pub fn text(self: KeyEvent) ?u21 {
        return switch (self.key) {
            .character => |codepoint| if (self.modifiers.normalized().isCommand())
                null
            else
                codepoint,
            .named => null,
        };
    }
};

/// The Conduit key an OS key names, and the intent key it is.
///
/// These are one switch rather than two because they are one decision: a key
/// is either one of the keys a terminal program binds by name or it is a
/// character, and the encoder and the registry must never disagree about which
/// of a press it was. `null` means a key with no name and no character — a
/// media key, a modifier, a keypad key Conduit does not encode — which is a
/// real answer: there is nothing to bind and nothing to send.
pub const IntentKey = struct {
    /// The key as a binding sees it.
    named: Named,
    /// The same key as the terminal encoder sees it.
    encoded: term.PhysicalKey,
};
pub fn intentOf(key: platform.Key) ?IntentKey {
    return switch (key) {
        .unidentified => null,
        .enter => .{ .named = .enter, .encoded = .enter },
        .tab => .{ .named = .tab, .encoded = .tab },
        .backspace => .{ .named = .backspace, .encoded = .backspace },
        .escape => .{ .named = .escape, .encoded = .escape },
        .insert => .{ .named = .insert, .encoded = .insert },
        .delete => .{ .named = .delete, .encoded = .delete },
        .up => .{ .named = .up, .encoded = .up },
        .down => .{ .named = .down, .encoded = .down },
        .left => .{ .named = .left, .encoded = .left },
        .right => .{ .named = .right, .encoded = .right },
        .home => .{ .named = .home, .encoded = .home },
        .end => .{ .named = .end, .encoded = .end },
        .page_up => .{ .named = .page_up, .encoded = .page_up },
        .page_down => .{ .named = .page_down, .encoded = .page_down },
        .f1 => .{ .named = .f1, .encoded = .f1 },
        .f2 => .{ .named = .f2, .encoded = .f2 },
        .f3 => .{ .named = .f3, .encoded = .f3 },
        .f4 => .{ .named = .f4, .encoded = .f4 },
        .f5 => .{ .named = .f5, .encoded = .f5 },
        .f6 => .{ .named = .f6, .encoded = .f6 },
        .f7 => .{ .named = .f7, .encoded = .f7 },
        .f8 => .{ .named = .f8, .encoded = .f8 },
        .f9 => .{ .named = .f9, .encoded = .f9 },
        .f10 => .{ .named = .f10, .encoded = .f10 },
        .f11 => .{ .named = .f11, .encoded = .f11 },
        .f12 => .{ .named = .f12, .encoded = .f12 },
    };
}

/// Every named key, for the tests and for a future binding table to walk.
pub const named_keys = std.enums.values(Named);

/// One key press, in both layers at once.
///
/// Both are produced because a press needs both before anything can be decided
/// about it: the bindings ask `intent` whether this is theirs, and if it is
/// not theirs the terminal gets `encoded`. Building one from the other would
/// mean either losing the intent or losing the encoding, and both are needed on
/// the same press.
pub const Press = struct {
    /// The press as intent, or null when it is not something to bind or send.
    intent: ?KeyEvent,
    /// The press as the terminal encoder takes it.
    encoded: term.KeyPress,
};

/// Scratch space for the text one press produces, owned by the caller.
///
/// A press carries its character as UTF-8, and a UTF-8 encoding of one
/// codepoint is at most four bytes. The press itself borrows this, so the
/// scratch is whatever the caller already has: the input state that drives the
/// loop, not a fresh allocation per keystroke and not a global that two events
/// on two threads would share. One scratch per press in flight is enough,
/// because a press is encoded and handed on before the next one arrives.
pub const TextScratch = struct {
    buffer: [4]u8 = undefined,
    /// How many bytes of `buffer` are text. Zero until a press fills it.
    len: usize = 0,

    /// The text a press put here.
    pub fn text(self: *const TextScratch) []const u8 {
        return self.buffer[0..self.len];
    }
};

/// Turn one key transition from the OS into both layers.
///
/// `composing` is whether an input method is composing right now. It is passed
/// in rather than looked up, because only the caller knows whether the text
/// arriving next is a preedit or a keystroke, and because this function stays
/// a pure translation: given the same OS event and the same answer it produces
/// the same press, which is what makes the table below a table rather than a
/// claim.
///
/// `scratch` receives the press's text and is borrowed by the result, so the
/// caller must keep it alive for as long as the press is held.
pub fn translate(scratch: *TextScratch, raw: platform.KeyEvent, composing: bool) Press {
    const named = intentOf(raw.key);

    // The character this press produces. A named key has none of its own, and a
    // control character is not one either: a C0 byte is what the *encoder*
    // makes of ctrl and the letter, so handing the control over here as well
    // would send it twice — and on a platform that reports ctrl+c as the
    // keycode 0x03 it would send it with nothing held at all.
    const character: ?u21 = if (named != null or isControl(raw.codepoint))
        null
    else
        raw.codepoint;

    scratch.len = 0;
    if (character) |codepoint| {
        scratch.len = std.unicode.utf8Encode(codepoint, &scratch.buffer) catch 0;
    }

    const mods = modifiersFrom(raw.mods);

    return .{
        .intent = if (named) |entry| KeyEvent{
            .key = .{ .named = entry.named },
            .modifiers = mods,
        } else if (character) |codepoint| KeyEvent{
            .key = .{ .character = codepoint },
            .modifiers = mods,
        } else null,
        .encoded = .{
            .action = actionFrom(raw.action),
            .key = if (named) |entry| entry.encoded else .unidentified,
            .mods = keyMods(raw.mods),
            // Shift is consumed when it is what turned the key into this
            // character. That is the difference between ctrl+a (0x01) and
            // ctrl+shift+a (a sequence), which a program can still tell apart.
            .consumed_mods = .{ .shift = raw.mods.shift and character != null },
            .text = scratch.text(),
            .unshifted_codepoint = raw.unshifted_codepoint,
            .composing = composing,
        },
    };
}

/// Whether `codepoint` is one of the characters that are not text: the C0
/// controls, DEL, and the C1 controls.
///
/// The same rule `Key.fromCharacter` refuses a character key for, kept as one
/// function because this is now asked twice — once when deciding whether a
/// press produces text, once when deciding whether it produces a bindable
/// character — and the two answers must be the same answer.
fn isControl(codepoint: u21) bool {
    return codepoint < 0x20 or
        codepoint == 0x7f or
        (codepoint >= 0x80 and codepoint < 0xa0);
}

/// The action an OS key transition is, in the encoder's terms.
fn actionFrom(action: platform.KeyAction) term.KeyAction {
    return switch (action) {
        .press => .press,
        .release => .release,
        .repeat => .repeat,
    };
}

/// The OS modifier set as intent modifiers.
fn modifiersFrom(mods: platform.Mods) Modifiers {
    return .{
        .ctrl = mods.ctrl,
        .alt = mods.alt,
        .shift = mods.shift,
        .super = mods.super,
        .caps_lock = mods.caps_lock,
        .num_lock = mods.num_lock,
    };
}

/// The OS modifier set as the encoder's modifiers.
fn keyMods(mods: platform.Mods) term.KeyMods {
    return .{
        .ctrl = mods.ctrl,
        .alt = mods.alt,
        .shift = mods.shift,
        .super = mods.super,
        .caps_lock = mods.caps_lock,
        .num_lock = mods.num_lock,
    };
}

// ---------------------------------------------------------------------------
// Actions and key bindings
// ---------------------------------------------------------------------------

/// One named string argument passed to an action.
///
/// Both slices are borrowed for the invocation. Empty, malformed UTF-8 and
/// control-bearing strings are rejected by `Registry.invoke` before a handler
/// sees them.
pub const Argument = struct {
    name: []const u8,
    value: []const u8,
};

/// The user gesture that asked for an action.
pub const InvocationSource = enum {
    keybinding,
    mouse,
    palette,
};

/// The context common to every action invocation.
///
/// `origin` identifies the semantic element a mouse or focused-key gesture
/// came from. The argument slice and every string in it are borrowed for the
/// call to the handler.
pub const Invocation = struct {
    source: InvocationSource,
    origin: ?ui.Id = null,
    arguments: []const Argument = &.{},
};

/// An action implementation. Handler failures are returned unchanged by the
/// registry so application errors are never converted into a successful
/// command.
pub const ActionHandler = *const fn (context: *anyopaque, invocation: Invocation) anyerror!void;

/// One fixed value a palette command may offer for an argument.
///
/// Both strings are borrowed for the registered definition's lifetime.
pub const PaletteChoice = struct {
    label: []const u8,
    value: []const u8,
};

/// The argument, if any, the palette collects before invoking an action.
///
/// Names become `Argument.name`, prompts are user-facing text and every slice
/// is borrowed for the registered definition's lifetime.
pub const PaletteArgument = union(enum) {
    none,
    input: struct {
        name: []const u8,
        prompt: []const u8,
    },
    choices: struct {
        name: []const u8,
        prompt: []const u8,
        values: []const PaletteChoice,
    },
};

/// Palette-specific action metadata.
pub const PaletteCommand = struct {
    argument: PaletteArgument = .none,
};

/// One command exposed by Conduit.
///
/// `name` is the stable programmatic identity and `label` is its user-facing
/// text. Both are borrowed and must remain alive while their definition is in
/// the registry. User-facing actions appear in the palette by default;
/// semantic-only actions opt out with `palette = null`.
pub const ActionDefinition = struct {
    name: []const u8,
    label: []const u8,
    handler: ActionHandler,
    palette: ?PaletteCommand = .{},
};

/// Registration failures that can be established without invoking an action.
pub const RegistryError = error{
    InvalidDefinition,
    DuplicateAction,
    RegistryFull,
};

/// Invocation failures owned by the registry rather than by an action.
pub const InvocationError = error{
    UnknownAction,
    InvalidInvocation,
};

/// An allocation-free action registry backed by storage its caller owns.
///
/// The storage and the strings in registered definitions must outlive the
/// registry. Enumeration is registration order, lookup is exact and no action
/// exists unless it was registered successfully.
pub const Registry = struct {
    storage: []ActionDefinition,
    len: usize = 0,

    /// Start an empty registry using `storage` as its fixed capacity.
    pub fn init(storage: []ActionDefinition) Registry {
        return .{ .storage = storage };
    }

    /// Register one action without allocating.
    pub fn register(self: *Registry, definition: ActionDefinition) RegistryError!void {
        if (!validMetadata(definition.name) or !validMetadata(definition.label)) {
            return error.InvalidDefinition;
        }
        if (definition.palette) |palette| {
            if (!validPaletteCommand(palette)) return error.InvalidDefinition;
        }
        if (self.lookup(definition.name) != null) return error.DuplicateAction;
        if (self.len == self.storage.len) return error.RegistryFull;

        self.storage[self.len] = definition;
        self.len += 1;
    }

    /// Registered definitions in deterministic registration order.
    pub fn definitions(self: *const Registry) []const ActionDefinition {
        return self.storage[0..self.len];
    }

    /// Find an action by its exact stable name.
    pub fn lookup(self: *const Registry, name: []const u8) ?*const ActionDefinition {
        for (self.storage[0..self.len]) |*definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    /// Invoke a registered action, returning lookup, metadata and handler
    /// errors to the caller.
    pub fn invoke(
        self: *const Registry,
        context: *anyopaque,
        name: []const u8,
        invocation: Invocation,
    ) anyerror!void {
        const definition = self.lookup(name) orelse return error.UnknownAction;
        if (!validInvocation(invocation)) return error.InvalidInvocation;
        return definition.handler(context, invocation);
    }
};

/// Whether externally visible action metadata is safe text.
fn validMetadata(text: []const u8) bool {
    if (text.len == 0) return false;
    const view = std.unicode.Utf8View.init(text) catch return false;
    var iterator = view.iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        if (isControl(codepoint)) return false;
    }
    return true;
}

/// Validate palette metadata without copying it. Choice labels and values are
/// both unique so a visible row and its eventual invocation stay unambiguous.
fn validPaletteCommand(command: PaletteCommand) bool {
    return switch (command.argument) {
        .none => true,
        .input => |argument| validMetadata(argument.name) and validMetadata(argument.prompt),
        .choices => |argument| choices: {
            if (!validMetadata(argument.name) or
                !validMetadata(argument.prompt) or
                argument.values.len == 0)
            {
                break :choices false;
            }
            for (argument.values, 0..) |choice, index| {
                if (!validMetadata(choice.label) or !validMetadata(choice.value)) {
                    break :choices false;
                }
                for (argument.values[0..index]) |previous| {
                    if (std.mem.eql(u8, choice.label, previous.label) or
                        std.mem.eql(u8, choice.value, previous.value))
                    {
                        break :choices false;
                    }
                }
            }
            break :choices true;
        },
    };
}

/// Validate all borrowed metadata before handing an invocation to application
/// code. An `Id` can be constructed as a value, so parse it again at this
/// trust boundary instead of assuming its producer called `Id.parse`.
fn validInvocation(invocation: Invocation) bool {
    if (invocation.origin) |origin| {
        _ = ui.Id.parse(origin.value) catch return false;
    }
    for (invocation.arguments) |argument| {
        if (!validMetadata(argument.name) or !validMetadata(argument.value)) return false;
    }
    return true;
}

/// The two platform conventions whose shipped bindings differ.
pub const PlatformProfile = enum {
    macos,
    linux_windows,

    /// The profile expected by this build's users.
    pub const native: PlatformProfile = if (builtin.os.tag == .macos) .macos else .linux_windows;
};

/// The key identity a binding matches, independent of its displayed glyph.
pub const BindingKey = union(enum) {
    character: u21,
    named: Named,
};

/// One exact key chord. Lock modifiers are ignored; every other modifier is
/// intent, so an extra Ctrl, Alt, Shift or Super prevents a match.
pub const Chord = struct {
    key: BindingKey,
    modifiers: Modifiers = .{},
};

/// One key chord's registered action request.
///
/// All strings are borrowed for the table's lifetime. Arguments are passed to
/// the handler exactly as written here after validation by the registry.
pub const Binding = struct {
    chord: Chord,
    action: []const u8,
    arguments: []const Argument = &.{},
};

/// The key identities whose presses were claimed by app bindings.
///
/// The caller owns `storage` and keeps it alive while this state is used. Its
/// fixed length is the maximum number of app-bound keys that may be held at
/// once; routing allocates nothing. Ownership is recorded by key identity
/// rather than modifiers because users may release modifiers before the key.
pub const BindingState = struct {
    storage: []BindingKey,
    len: usize = 0,

    /// Start with no claimed keys and caller-owned fixed-capacity storage.
    pub fn init(storage: []BindingKey) BindingState {
        return .{ .storage = storage };
    }

    fn indexOf(self: *const BindingState, key: BindingKey) ?usize {
        for (self.storage[0..self.len], 0..) |claimed, index| {
            if (bindingKeyEql(claimed, key)) return index;
        }
        return null;
    }

    fn claim(self: *BindingState, key: BindingKey) bool {
        if (self.len == self.storage.len) return false;
        self.storage[self.len] = key;
        self.len += 1;
        return true;
    }

    fn release(self: *BindingState, index: usize) void {
        var destination = index;
        while (destination + 1 < self.len) : (destination += 1) {
            self.storage[destination] = self.storage[destination + 1];
        }
        self.len -= 1;
    }
};

const tab_goto_1_arguments = [_]Argument{.{ .name = "index", .value = "1" }};
const tab_goto_2_arguments = [_]Argument{.{ .name = "index", .value = "2" }};
const tab_goto_3_arguments = [_]Argument{.{ .name = "index", .value = "3" }};
const tab_goto_4_arguments = [_]Argument{.{ .name = "index", .value = "4" }};
const tab_goto_5_arguments = [_]Argument{.{ .name = "index", .value = "5" }};
const tab_goto_6_arguments = [_]Argument{.{ .name = "index", .value = "6" }};
const tab_goto_7_arguments = [_]Argument{.{ .name = "index", .value = "7" }};
const tab_goto_8_arguments = [_]Argument{.{ .name = "index", .value = "8" }};
const tab_goto_9_arguments = [_]Argument{.{ .name = "index", .value = "9" }};
const tab_move_up_arguments = [_]Argument{.{ .name = "direction", .value = "up" }};
const tab_move_down_arguments = [_]Argument{.{ .name = "direction", .value = "down" }};
const pane_right_arguments = [_]Argument{.{ .name = "direction", .value = "right" }};
const pane_down_arguments = [_]Argument{.{ .name = "direction", .value = "down" }};
const pane_left_arguments = [_]Argument{.{ .name = "direction", .value = "left" }};
const pane_up_arguments = [_]Argument{.{ .name = "direction", .value = "up" }};

const macos_default_bindings = [_]Binding{
    .{ .chord = .{ .key = .{ .character = 'c' }, .modifiers = .{ .super = true } }, .action = "clipboard.copy" },
    .{ .chord = .{ .key = .{ .character = 'v' }, .modifiers = .{ .super = true } }, .action = "clipboard.paste" },
    .{ .chord = .{ .key = .{ .character = 'b' }, .modifiers = .{ .shift = true, .super = true } }, .action = "sidebar.toggle" },
    .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .shift = true, .super = true } }, .action = "sidebar.narrow" },
    .{ .chord = .{ .key = .{ .named = .right }, .modifiers = .{ .shift = true, .super = true } }, .action = "sidebar.widen" },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .shift = true, .super = true } }, .action = "sidebar.focus" },
    .{ .chord = .{ .key = .{ .character = 't' }, .modifiers = .{ .super = true } }, .action = "tab.new" },
    .{ .chord = .{ .key = .{ .character = 'w' }, .modifiers = .{ .super = true } }, .action = "tab.close" },
    .{ .chord = .{ .key = .{ .named = .f2 } }, .action = "tab.rename" },
    .{ .chord = .{ .key = .{ .character = '[' }, .modifiers = .{ .shift = true, .super = true } }, .action = "tab.previous" },
    .{ .chord = .{ .key = .{ .character = ']' }, .modifiers = .{ .shift = true, .super = true } }, .action = "tab.next" },
    .{ .chord = .{ .key = .{ .character = '1' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_1_arguments },
    .{ .chord = .{ .key = .{ .character = '2' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_2_arguments },
    .{ .chord = .{ .key = .{ .character = '3' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_3_arguments },
    .{ .chord = .{ .key = .{ .character = '4' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_4_arguments },
    .{ .chord = .{ .key = .{ .character = '5' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_5_arguments },
    .{ .chord = .{ .key = .{ .character = '6' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_6_arguments },
    .{ .chord = .{ .key = .{ .character = '7' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_7_arguments },
    .{ .chord = .{ .key = .{ .character = '8' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_8_arguments },
    .{ .chord = .{ .key = .{ .character = '9' }, .modifiers = .{ .super = true } }, .action = "tab.goto", .arguments = &tab_goto_9_arguments },
    .{ .chord = .{ .key = .{ .named = .up }, .modifiers = .{ .alt = true, .shift = true } }, .action = "tab.move", .arguments = &tab_move_up_arguments },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .alt = true, .shift = true } }, .action = "tab.move", .arguments = &tab_move_down_arguments },
    .{ .chord = .{ .key = .{ .character = 'd' }, .modifiers = .{ .super = true } }, .action = "pane.split", .arguments = &pane_right_arguments },
    .{ .chord = .{ .key = .{ .character = 'd' }, .modifiers = .{ .shift = true, .super = true } }, .action = "pane.split", .arguments = &pane_down_arguments },
    .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .alt = true, .super = true } }, .action = "pane.focus", .arguments = &pane_left_arguments },
    .{ .chord = .{ .key = .{ .named = .right }, .modifiers = .{ .alt = true, .super = true } }, .action = "pane.focus", .arguments = &pane_right_arguments },
    .{ .chord = .{ .key = .{ .named = .up }, .modifiers = .{ .alt = true, .super = true } }, .action = "pane.focus", .arguments = &pane_up_arguments },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .alt = true, .super = true } }, .action = "pane.focus", .arguments = &pane_down_arguments },
    .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .ctrl = true, .super = true } }, .action = "pane.resize", .arguments = &pane_left_arguments },
    .{ .chord = .{ .key = .{ .named = .right }, .modifiers = .{ .ctrl = true, .super = true } }, .action = "pane.resize", .arguments = &pane_right_arguments },
    .{ .chord = .{ .key = .{ .named = .up }, .modifiers = .{ .ctrl = true, .super = true } }, .action = "pane.resize", .arguments = &pane_up_arguments },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .ctrl = true, .super = true } }, .action = "pane.resize", .arguments = &pane_down_arguments },
    .{ .chord = .{ .key = .{ .named = .enter }, .modifiers = .{ .shift = true, .super = true } }, .action = "pane.zoom" },
    .{ .chord = .{ .key = .{ .character = 'x' }, .modifiers = .{ .shift = true, .super = true } }, .action = "pane.close" },
    .{ .chord = .{ .key = .{ .character = '`' }, .modifiers = .{ .super = true } }, .action = "scratchpad.toggle-50" },
    .{ .chord = .{ .key = .{ .character = '`' }, .modifiers = .{ .shift = true, .super = true } }, .action = "scratchpad.toggle-90" },
    .{ .chord = .{ .key = .{ .character = 'p' }, .modifiers = .{ .shift = true, .super = true } }, .action = "palette.open" },
    .{ .chord = .{ .key = .{ .named = .f10 }, .modifiers = .{ .shift = true } }, .action = "terminal.context-menu" },
    .{ .chord = .{ .key = .{ .character = ',' }, .modifiers = .{ .super = true } }, .action = "config.open" },
    .{ .chord = .{ .key = .{ .character = '=' }, .modifiers = .{ .super = true } }, .action = "font.size.increase" },
    // Command+Plus on a layout where `+` is Shift+`=`.
    .{ .chord = .{ .key = .{ .character = '=' }, .modifiers = .{ .shift = true, .super = true } }, .action = "font.size.increase" },
    .{ .chord = .{ .key = .{ .character = '-' }, .modifiers = .{ .super = true } }, .action = "font.size.decrease" },
    .{ .chord = .{ .key = .{ .character = '0' }, .modifiers = .{ .super = true } }, .action = "font.size.reset" },
    .{ .chord = .{ .key = .{ .character = ',' }, .modifiers = .{ .shift = true, .super = true } }, .action = "settings.open" },
};

const linux_windows_default_bindings = [_]Binding{
    .{ .chord = .{ .key = .{ .character = 'c' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "clipboard.copy" },
    .{ .chord = .{ .key = .{ .character = 'v' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "clipboard.paste" },
    .{ .chord = .{ .key = .{ .character = 'b' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "sidebar.toggle" },
    .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "sidebar.narrow" },
    .{ .chord = .{ .key = .{ .named = .right }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "sidebar.widen" },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "sidebar.focus" },
    .{ .chord = .{ .key = .{ .character = 't' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "tab.new" },
    .{ .chord = .{ .key = .{ .character = 'w' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "tab.close" },
    .{ .chord = .{ .key = .{ .named = .f2 } }, .action = "tab.rename" },
    .{ .chord = .{ .key = .{ .named = .page_up }, .modifiers = .{ .ctrl = true } }, .action = "tab.previous" },
    .{ .chord = .{ .key = .{ .named = .page_down }, .modifiers = .{ .ctrl = true } }, .action = "tab.next" },
    .{ .chord = .{ .key = .{ .character = '1' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_1_arguments },
    .{ .chord = .{ .key = .{ .character = '2' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_2_arguments },
    .{ .chord = .{ .key = .{ .character = '3' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_3_arguments },
    .{ .chord = .{ .key = .{ .character = '4' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_4_arguments },
    .{ .chord = .{ .key = .{ .character = '5' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_5_arguments },
    .{ .chord = .{ .key = .{ .character = '6' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_6_arguments },
    .{ .chord = .{ .key = .{ .character = '7' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_7_arguments },
    .{ .chord = .{ .key = .{ .character = '8' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_8_arguments },
    .{ .chord = .{ .key = .{ .character = '9' }, .modifiers = .{ .alt = true } }, .action = "tab.goto", .arguments = &tab_goto_9_arguments },
    .{ .chord = .{ .key = .{ .named = .up }, .modifiers = .{ .alt = true, .shift = true } }, .action = "tab.move", .arguments = &tab_move_up_arguments },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .alt = true, .shift = true } }, .action = "tab.move", .arguments = &tab_move_down_arguments },
    .{ .chord = .{ .key = .{ .character = 'e' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "pane.split", .arguments = &pane_right_arguments },
    .{ .chord = .{ .key = .{ .character = 'o' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "pane.split", .arguments = &pane_down_arguments },
    .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .alt = true } }, .action = "pane.focus", .arguments = &pane_left_arguments },
    .{ .chord = .{ .key = .{ .named = .right }, .modifiers = .{ .alt = true } }, .action = "pane.focus", .arguments = &pane_right_arguments },
    .{ .chord = .{ .key = .{ .named = .up }, .modifiers = .{ .alt = true } }, .action = "pane.focus", .arguments = &pane_up_arguments },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .alt = true } }, .action = "pane.focus", .arguments = &pane_down_arguments },
    .{ .chord = .{ .key = .{ .named = .left }, .modifiers = .{ .ctrl = true, .alt = true } }, .action = "pane.resize", .arguments = &pane_left_arguments },
    .{ .chord = .{ .key = .{ .named = .right }, .modifiers = .{ .ctrl = true, .alt = true } }, .action = "pane.resize", .arguments = &pane_right_arguments },
    .{ .chord = .{ .key = .{ .named = .up }, .modifiers = .{ .ctrl = true, .alt = true } }, .action = "pane.resize", .arguments = &pane_up_arguments },
    .{ .chord = .{ .key = .{ .named = .down }, .modifiers = .{ .ctrl = true, .alt = true } }, .action = "pane.resize", .arguments = &pane_down_arguments },
    .{ .chord = .{ .key = .{ .named = .enter }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "pane.zoom" },
    .{ .chord = .{ .key = .{ .character = 'x' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "pane.close" },
    .{ .chord = .{ .key = .{ .character = '`' }, .modifiers = .{ .ctrl = true } }, .action = "scratchpad.toggle-50" },
    .{ .chord = .{ .key = .{ .character = '`' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "scratchpad.toggle-90" },
    .{ .chord = .{ .key = .{ .character = 'p' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "palette.open" },
    .{ .chord = .{ .key = .{ .named = .f10 }, .modifiers = .{ .shift = true } }, .action = "terminal.context-menu" },
    .{ .chord = .{ .key = .{ .character = ',' }, .modifiers = .{ .ctrl = true } }, .action = "config.open" },
    // Ctrl+=, Ctrl+- and Ctrl+0 are the zoom chords of browsers and other terminals. The legacy
    // terminal encoding has no control code for `=` or `0` (both reach a program as the plain
    // character) and Ctrl+- is not a C0 control on its own key, so no common program loses input.
    .{ .chord = .{ .key = .{ .character = '=' }, .modifiers = .{ .ctrl = true } }, .action = "font.size.increase" },
    // Ctrl+Plus on a layout where `+` is Shift+`=`.
    .{ .chord = .{ .key = .{ .character = '=' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "font.size.increase" },
    .{ .chord = .{ .key = .{ .character = '-' }, .modifiers = .{ .ctrl = true } }, .action = "font.size.decrease" },
    .{ .chord = .{ .key = .{ .character = '0' }, .modifiers = .{ .ctrl = true } }, .action = "font.size.reset" },
    // Ctrl+Shift+, has no C0 control code and no common program binds it; it pairs with Ctrl+,
    // (the raw file) the way editors pair a settings view with its file.
    .{ .chord = .{ .key = .{ .character = ',' }, .modifiers = .{ .ctrl = true, .shift = true } }, .action = "settings.open" },
};

/// Conduit's deterministic shipped bindings for `profile`.
pub fn defaultBindings(profile: PlatformProfile) []const Binding {
    return switch (profile) {
        .macos => &macos_default_bindings,
        .linux_windows => &linux_windows_default_bindings,
    };
}

// ---------------------------------------------------------------------------
// Configured bindings (TASK-37)
// ---------------------------------------------------------------------------

/// Why a chord spelling from the settings file was rejected.
pub const ChordError = error{
    EmptyChord,
    UnknownModifier,
    DuplicateModifier,
    MissingKey,
    UnknownKey,
};

/// Words accepted for a character key that cannot be written literally inside a chord, or that
/// read better spelled out. `plus` and `equal` are required: `+` separates the chord's parts and
/// the settings file splits a keybind at its first `=`.
const character_names = [_]struct { name: []const u8, codepoint: u21 }{
    .{ .name = "space", .codepoint = ' ' },
    .{ .name = "plus", .codepoint = '+' },
    .{ .name = "equal", .codepoint = '=' },
    .{ .name = "minus", .codepoint = '-' },
    .{ .name = "comma", .codepoint = ',' },
    .{ .name = "period", .codepoint = '.' },
    .{ .name = "slash", .codepoint = '/' },
    .{ .name = "backslash", .codepoint = '\\' },
    .{ .name = "semicolon", .codepoint = ';' },
    .{ .name = "backtick", .codepoint = '`' },
    .{ .name = "grave", .codepoint = '`' },
};

/// Named-key words. Each `Named` tag is accepted as written (`page_up`, `f10`); these add the
/// common alternative spellings.
const named_aliases = [_]struct { name: []const u8, named: Named }{
    .{ .name = "return", .named = .enter },
    .{ .name = "esc", .named = .escape },
    .{ .name = "pageup", .named = .page_up },
    .{ .name = "pagedown", .named = .page_down },
    .{ .name = "del", .named = .delete },
    .{ .name = "ins", .named = .insert },
};

/// Parse a chord spelling such as `ctrl+shift+t`, `super+,`, `shift+f10` or `ctrl+backtick`.
///
/// Parts are separated by `+` and matched case-insensitively. Every part but the last is a
/// modifier: `ctrl` (`control`), `shift`, `alt` (`option`, `opt`) or `super` (`cmd`, `command`).
/// The last part is the key: a named key, a word from `character_names`, or one character. A
/// letter is stored lowercase because bindings match the unshifted key identity; a shifted symbol
/// is spelled as its unshifted key plus `shift` (`ctrl+shift+[`, not `ctrl+{`).
pub fn parseChord(text: []const u8) ChordError!Chord {
    if (text.len == 0) return error.EmptyChord;
    var modifiers: Modifiers = .{};
    var parts = std.mem.splitScalar(u8, text, '+');
    var current = parts.next() orelse return error.EmptyChord;
    while (parts.next()) |next| {
        const part = std.mem.trim(u8, current, " \t");
        if (part.len == 0) return error.MissingKey;
        const field = modifierField(part) orelse return error.UnknownModifier;
        switch (field) {
            .ctrl => if (modifiers.ctrl) return error.DuplicateModifier else {
                modifiers.ctrl = true;
            },
            .shift => if (modifiers.shift) return error.DuplicateModifier else {
                modifiers.shift = true;
            },
            .alt => if (modifiers.alt) return error.DuplicateModifier else {
                modifiers.alt = true;
            },
            .super => if (modifiers.super) return error.DuplicateModifier else {
                modifiers.super = true;
            },
        }
        current = next;
    }
    const key_text = std.mem.trim(u8, current, " \t");
    if (key_text.len == 0) return error.MissingKey;
    return .{ .key = try parseBindingKey(key_text), .modifiers = modifiers };
}

const ModifierField = enum { ctrl, shift, alt, super };

fn modifierField(part: []const u8) ?ModifierField {
    const spellings = [_]struct { name: []const u8, field: ModifierField }{
        .{ .name = "ctrl", .field = .ctrl },
        .{ .name = "control", .field = .ctrl },
        .{ .name = "shift", .field = .shift },
        .{ .name = "alt", .field = .alt },
        .{ .name = "option", .field = .alt },
        .{ .name = "opt", .field = .alt },
        .{ .name = "super", .field = .super },
        .{ .name = "cmd", .field = .super },
        .{ .name = "command", .field = .super },
    };
    for (spellings) |spelling| {
        if (std.ascii.eqlIgnoreCase(part, spelling.name)) return spelling.field;
    }
    return null;
}

fn parseBindingKey(text: []const u8) ChordError!BindingKey {
    for (std.enums.values(Named)) |named| {
        if (std.ascii.eqlIgnoreCase(text, @tagName(named))) return .{ .named = named };
    }
    for (named_aliases) |alias| {
        if (std.ascii.eqlIgnoreCase(text, alias.name)) return .{ .named = alias.named };
    }
    for (character_names) |word| {
        if (std.ascii.eqlIgnoreCase(text, word.name)) return .{ .character = word.codepoint };
    }
    const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return error.UnknownKey;
    if (length != text.len) return error.UnknownKey;
    const codepoint = std.unicode.utf8Decode(text) catch return error.UnknownKey;
    if (codepoint == ' ' or isControl(codepoint)) return error.UnknownKey;
    if (codepoint < 0x80) return .{ .character = std.ascii.toLower(@intCast(codepoint)) };
    return .{ .character = codepoint };
}

/// Whether two chords match the same key transitions: same key, same intent modifiers.
pub fn chordEql(a: Chord, b: Chord) bool {
    return bindingKeyEql(a.key, b.key) and std.meta.eql(a.modifiers.normalized(), b.modifiers.normalized());
}

/// The chord a raw key press is, as a binding would match it: the layout-independent key plus the
/// intent modifiers. Null for a transition with no key identity of its own, such as a modifier key
/// pressed alone or a control codepoint.
pub fn chordOf(raw: platform.KeyEvent) ?Chord {
    const key = bindingKey(raw) orelse return null;
    return .{ .key = key, .modifiers = modifiersFrom(raw.mods).normalized() };
}

/// Whether `chord` would type text if it were bound: a character key with no Ctrl, Alt or Super.
/// Shift alone still types, so `shift+a` counts too.
pub fn chordTypesText(chord: Chord) bool {
    return switch (chord.key) {
        .character => !chord.modifiers.isCommand(),
        .named => false,
    };
}

/// The first binding in table order whose chord is `chord`: the one a press of it dispatches.
/// Borrowed from `bindings`.
pub fn findBinding(bindings: []const Binding, chord: Chord) ?*const Binding {
    for (bindings) |*binding| {
        if (chordEql(binding.chord, chord)) return binding;
    }
    return null;
}

/// The settings-file spelling of `chord` that `parseChord` reads back as the same chord:
/// `ctrl+alt+super+shift+<key>`, the key a named key's tag (`page_up`, `f10`), a lowercase letter,
/// one character, or the word for a character a chord cannot hold (`plus`, `equal`, `space`).
pub fn formatChordSpelling(buffer: []u8, chord: Chord) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    const modifiers = chord.modifiers.normalized();
    if (modifiers.ctrl) writer.writeAll("ctrl+") catch return error.NoSpaceLeft;
    if (modifiers.alt) writer.writeAll("alt+") catch return error.NoSpaceLeft;
    if (modifiers.super) writer.writeAll("super+") catch return error.NoSpaceLeft;
    if (modifiers.shift) writer.writeAll("shift+") catch return error.NoSpaceLeft;
    switch (chord.key) {
        .named => |named| writer.writeAll(@tagName(named)) catch return error.NoSpaceLeft,
        .character => |codepoint| {
            const word: ?[]const u8 = switch (codepoint) {
                '+' => "plus",
                '=' => "equal",
                ' ' => "space",
                else => null,
            };
            if (word) |text| {
                writer.writeAll(text) catch return error.NoSpaceLeft;
            } else {
                var encoded: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.NoSpaceLeft;
                writer.writeAll(encoded[0..length]) catch return error.NoSpaceLeft;
            }
        },
    }
    return writer.buffered();
}

/// One configured change to the binding table.
///
/// Every slice is borrowed for the `buildBindings` call only; the table copies what it keeps.
pub const BindingOverride = struct {
    chord: Chord,
    /// The action to bind, or null to unbind the chord.
    action: ?[]const u8,
    arguments: []const Argument = &.{},
};

/// A binding table built from the shipped defaults plus configured overrides.
///
/// Owns `bindings` and every string an override contributed; strings from the shipped defaults
/// are static and borrowed. Replaced wholesale on reload, on the owner (main) thread.
pub const BindingTable = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []const Binding = &.{},

    pub fn deinit(self: *BindingTable) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Build the binding table: `defaults` in order, then each override applied in file order.
///
/// An override first removes every binding whose chord equals its chord, so one chord never maps
/// to two actions; a binding then takes the position of the first binding it replaced (keeping the
/// palette's chord order stable) or goes at the end. An unbind only removes. Rebinding an action
/// to a new chord leaves its default chord bound; unbind that chord to move it.
pub fn buildBindings(
    gpa: std.mem.Allocator,
    defaults: []const Binding,
    overrides: []const BindingOverride,
) std.mem.Allocator.Error!BindingTable {
    var table: BindingTable = .{ .arena = .init(gpa) };
    errdefer table.deinit();
    const allocator = table.arena.allocator();

    var list: std.ArrayList(Binding) = .empty;
    try list.appendSlice(allocator, defaults);
    for (overrides) |override| {
        var insert_at: ?usize = null;
        var index: usize = 0;
        while (index < list.items.len) {
            if (chordEql(list.items[index].chord, override.chord)) {
                if (insert_at == null) insert_at = index;
                _ = list.orderedRemove(index);
            } else {
                index += 1;
            }
        }
        const action = override.action orelse continue;
        const arguments = try allocator.alloc(Argument, override.arguments.len);
        for (override.arguments, arguments) |from, *to| {
            to.* = .{ .name = try allocator.dupe(u8, from.name), .value = try allocator.dupe(u8, from.value) };
        }
        const binding: Binding = .{
            .chord = .{ .key = override.chord.key, .modifiers = override.chord.modifiers.normalized() },
            .action = try allocator.dupe(u8, action),
            .arguments = arguments,
        };
        try list.insert(allocator, insert_at orelse list.items.len, binding);
    }
    table.bindings = list.items;
    return table;
}

/// Why a configured keybind's action or argument was rejected.
pub const KeybindError = error{
    UnknownAction,
    NotBindable,
    MissingArgument,
    UnexpectedArgument,
    InvalidArgument,
};

/// The named argument a keybind for `action` passes, given the text after `:` (if any).
///
/// The argument's name comes from the action's palette contract, or, for an action the palette
/// does not list, from its shipped default bindings. An action that is neither palette-visible nor
/// bound by default is semantic plumbing (it needs a clicked element) and cannot be bound. A
/// fixed-choice argument must be one of its choices. The returned slices borrow `registry`
/// metadata and `value`.
pub fn keybindArgument(
    registry: *const Registry,
    defaults: []const Binding,
    action: []const u8,
    value: ?[]const u8,
) KeybindError!?Argument {
    const definition = registry.lookup(action) orelse return error.UnknownAction;
    var name: ?[]const u8 = null;
    if (definition.palette) |palette| {
        switch (palette.argument) {
            .none => {},
            .input => |argument| name = argument.name,
            .choices => |argument| {
                const text = value orelse return error.MissingArgument;
                for (argument.values) |choice| {
                    if (std.mem.eql(u8, choice.value, text)) return .{ .name = argument.name, .value = text };
                }
                return error.InvalidArgument;
            },
        }
    } else {
        var bound = false;
        for (defaults) |binding| {
            if (!std.mem.eql(u8, binding.action, action)) continue;
            bound = true;
            if (binding.arguments.len != 0) name = binding.arguments[0].name;
        }
        if (!bound) return error.NotBindable;
    }
    const argument_name = name orelse {
        if (value != null) return error.UnexpectedArgument;
        return null;
    };
    const text = value orelse return error.MissingArgument;
    if (!validMetadata(text)) return error.InvalidArgument;
    return .{ .name = argument_name, .value = text };
}

/// A named action and the invocation metadata a router should dispatch.
pub const ActionRequest = struct {
    action: []const u8,
    invocation: Invocation,
};

/// The result of routing one raw key transition.
pub const Route = union(enum) {
    /// A press matched a binding and should invoke this action once.
    action: ActionRequest,
    /// A release or repeat matched a binding whose press Conduit owned.
    consumed,
    /// No binding matched; this is the original translated terminal value.
    terminal: term.KeyPress,
};

/// Resolve one already-translated key transition against `bindings`.
///
/// Character chords use `raw.unshifted_codepoint`, never the shifted display
/// character. The first binding in table order wins. A matching press records
/// ownership before producing one request. Further presses and repeats for
/// that owned key are consumed, and its release is consumed and clears the
/// ownership even if the modifiers changed. An unowned repeat or release is
/// always the terminal's. If the fixed state cannot record a matching press,
/// that whole transition stays the terminal's rather than splitting ownership
/// between Conduit and the child.
///
/// Every terminal result carries `translated.encoded` directly so its borrowed
/// text and every encoder field survive unchanged.
pub fn resolve(
    state: *BindingState,
    raw: platform.KeyEvent,
    translated: Press,
    bindings: []const Binding,
) Route {
    const key = bindingKey(raw) orelse return .{ .terminal = translated.encoded };

    if (state.indexOf(key)) |owned_index| {
        if (raw.action == .release) state.release(owned_index);
        return .consumed;
    }

    // Only the press can establish ownership. A repeat or release without a
    // recorded press belongs to the terminal even when its current modifiers
    // happen to match a binding.
    if (raw.action != .press) return .{ .terminal = translated.encoded };

    const modifiers = modifiersFrom(raw.mods).normalized();

    for (bindings) |binding| {
        if (!bindingKeyEql(key, binding.chord.key)) continue;
        if (!std.meta.eql(modifiers, binding.chord.modifiers.normalized())) continue;
        if (!state.claim(key)) return .{ .terminal = translated.encoded };

        return .{ .action = .{
            .action = binding.action,
            .invocation = .{
                .source = .keybinding,
                .arguments = binding.arguments,
            },
        } };
    }

    return .{ .terminal = translated.encoded };
}

/// The layout-independent identity of a raw event, when it has one.
fn bindingKey(raw: platform.KeyEvent) ?BindingKey {
    if (intentOf(raw.key)) |intent| return .{ .named = intent.named };
    if (raw.unshifted_codepoint == 0 or isControl(raw.unshifted_codepoint)) return null;
    return .{ .character = raw.unshifted_codepoint };
}

fn bindingKeyEql(a: BindingKey, b: BindingKey) bool {
    return switch (a) {
        .character => |a_character| switch (b) {
            .character => |b_character| a_character == b_character,
            .named => false,
        },
        .named => |a_named| switch (b) {
            .character => false,
            .named => |b_named| a_named == b_named,
        },
    };
}

// ---------------------------------------------------------------------------
// Pointer
// ---------------------------------------------------------------------------

/// The geometry a pointer event needs to be turned into a cell, and nothing
/// else.
///
/// Passed by pointer and borrowed for the call. It is a value rather than four
/// loose parameters because these six numbers are always the same six: they
/// come from the surface and the font metrics, and a caller that could supply
/// three of them and leave the rest to a default would be able to name a cell
/// the mouse is not over.
pub const PointerGeometry = struct {
    /// The surface's size in pixels.
    surface_width_px: u32 = 0,
    surface_height_px: u32 = 0,
    /// One cell's size in pixels.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
};

/// Turn one button transition from the OS into the terminal's pointer event.
///
/// `geometry` is borrowed for the call. This is a pure translation — the same
/// OS event and the same geometry always produce the same event — which is
/// what makes the ownership decision (`term.pointerOwner`, and the Shift
/// override in it) testable without a terminal and a program in it.
pub fn pointerButton(
    geometry: *const PointerGeometry,
    raw: platform.PointerButton,
) term.PointerEvent {
    return .{
        .action = switch (raw.action) {
            .press => .press,
            // `repeat` cannot happen for a mouse button, and treating it as a
            // release would end a drag the moment the OS said "again".
            .repeat => .press,
            .release => .release,
        },
        .button = switch (raw.button) {
            .left => .left,
            .middle => .middle,
            .right => .right,
        },
        .mods = pointerMods(raw.mods),
        .any_button_pressed = raw.action == .press,
        .pointer = pointerFrom(geometry, raw.x, raw.y),
    };
}

/// Turn one motion report from the OS into the terminal's pointer event.
pub fn pointerMotion(
    geometry: *const PointerGeometry,
    raw: platform.PointerMotion,
) term.PointerEvent {
    return .{
        .action = .motion,
        // A motion names no button: which buttons are held is on the event, and
        // a motion is a motion whether one is held or not. Any-event mode
        // (DECSET 1003) is precisely the case where none is.
        .button = null,
        .mods = pointerMods(raw.mods),
        .any_button_pressed = raw.buttons.left or raw.buttons.middle or raw.buttons.right,
        .pointer = pointerFrom(geometry, raw.x, raw.y),
    };
}

/// The position and geometry half of a pointer event.
fn pointerFrom(geometry: *const PointerGeometry, x: f32, y: f32) term.Pointer {
    return .{
        .x = x,
        .y = y,
        .surface_width_px = geometry.surface_width_px,
        .surface_height_px = geometry.surface_height_px,
        .cell_width_px = geometry.cell_width_px,
        .cell_height_px = geometry.cell_height_px,
    };
}

/// The OS modifier set as the modifiers a mouse report carries.
///
/// Four of the six, because a mouse report has four: shift, alt, ctrl and the
/// command key are the X11 bits, and caps and num lock are not in any report
/// format. Shift is the one that decides ownership — `term.pointerOwner` gives
/// the user the pointer whenever it is held.
pub fn pointerMods(mods: platform.Mods) term.Mods {
    return .{
        .shift = mods.shift,
        .alt = mods.alt,
        .ctrl = mods.ctrl,
        .super = mods.super,
    };
}

// ---------------------------------------------------------------------------
// Clipboard
// ---------------------------------------------------------------------------

/// The copy and paste chords a platform's users already have in their hands.
///
/// A value rather than a build-time constant so both sets are tested on every
/// host: the macOS chords are decided here, and a Linux CI run that could not
/// see them would leave half of the table unproven.
pub const ClipboardChords = enum {
    /// Ctrl+Shift+C and Ctrl+Shift+V, the terminal convention on Linux and
    /// Windows. Shift is what keeps them clear of Ctrl+C and Ctrl+V, which a
    /// shell already owns (SIGINT and literal-next).
    ctrl_shift,
    /// Cmd+C and Cmd+V on macOS. Cmd never reaches a terminal program as a
    /// control character, so there is nothing for it to collide with.
    command,

    /// The set this build's users expect.
    pub const native: ClipboardChords = if (builtin.os.tag == .macos) .command else .ctrl_shift;
};

/// What a key decides about the clipboard, given what is on the screen.
pub const ClipboardKeyContext = struct {
    /// Whether the terminal has a selection right now.
    has_selection: bool,
    /// Which chord set is in force.
    chords: ClipboardChords = .native,
    /// Whether a plain Ctrl+C copies while there is a selection (TASK-15's
    /// "configurable", on until TASK-37 gives it a setting). It is never
    /// consulted without a selection: that case is SIGINT, unconditionally.
    ctrl_c_copies_selection: bool = true,
};

/// What one key press is, as far as the clipboard is concerned.
pub const ClipboardKey = enum {
    /// Copy the selection to the clipboard.
    copy,
    /// Copy the selection, then drop it. A plain Ctrl+C copy answers this, so
    /// the very next Ctrl+C — with nothing selected any more — is SIGINT again
    /// instead of a second copy the user did not ask for.
    copy_and_deselect,
    /// Paste the clipboard into the terminal.
    paste,
    /// A clipboard chord that does nothing this time: its release or repeat,
    /// or the copy chord with nothing selected. It is not sent to the program
    /// either, because the program never saw the press it would belong to.
    swallow,
    /// Not the clipboard's: encode it and send it to the program.
    terminal,
};

/// Decide whether a key press is a copy, a paste, or the program's.
///
/// The rule that matters most is the one this function cannot break: Ctrl+C
/// with nothing selected is the terminal's Ctrl+C — `0x03`, SIGINT — whatever
/// the chord set, the configuration, the lock keys or the action. No branch
/// below returns anything but `.terminal` for it, because every copy branch
/// requires either a selection or a modifier Ctrl+C does not have, and the
/// tests walk that whole space rather than sampling it (CONDUIT.md §7).
///
/// The letter is read from the layout's *unshifted* character, so Ctrl+Shift+C
/// is recognised whether the OS reported `C` or `c`. A layout whose key has no
/// Latin letter is never a chord here and goes to the program, which is the
/// safe direction to be wrong in. Pure: the same event and context always give
/// the same answer.
pub fn clipboardKey(raw: platform.KeyEvent, context: ClipboardKeyContext) ClipboardKey {
    if (raw.key != .unidentified) return .terminal;
    const letter = chordLetter(raw) orelse return .terminal;
    const mods = modifiersFrom(raw.mods).normalized();
    const pressed = raw.action == .press;

    const chord_mods: Modifiers = switch (context.chords) {
        .ctrl_shift => .{ .ctrl = true, .shift = true },
        .command => .{ .super = true },
    };
    if (std.meta.eql(mods, chord_mods)) {
        return switch (letter) {
            .c => if (pressed and context.has_selection) .copy else .swallow,
            .v => if (pressed) .paste else .swallow,
        };
    }

    // Plain Ctrl+C copies only with a selection, only when configured to, and
    // only on the Ctrl+Shift platforms: on macOS Cmd+C is the copy, so Ctrl+C
    // there is the program's whatever is selected.
    const plain_ctrl = std.meta.eql(mods, Modifiers{ .ctrl = true });
    if (letter == .c and plain_ctrl and context.has_selection and
        context.ctrl_c_copies_selection and context.chords == .ctrl_shift)
    {
        return if (pressed) .copy_and_deselect else .swallow;
    }
    return .terminal;
}

/// The two letters a clipboard chord is made of.
const ChordLetter = enum { c, v };

/// The chord letter the layout puts under the press, or null for any other key.
fn chordLetter(raw: platform.KeyEvent) ?ChordLetter {
    const codepoint = if (raw.unshifted_codepoint != 0) raw.unshifted_codepoint else raw.codepoint;
    return switch (codepoint) {
        'c', 'C' => .c,
        'v', 'V' => .v,
        else => null,
    };
}

/// Whether a pointer button is a paste of the primary selection.
///
/// Only a middle *press*, only on a platform that has a primary selection
/// (`platform.primary_selection_supported`, passed in so the other answer is
/// testable on Linux), and only when the user owns the pointer: a program that
/// captured the mouse gets its middle click as a report, and Shift takes the
/// pointer back exactly as it does for a selection (`term.pointerOwner`).
pub fn primaryPaste(raw: platform.PointerButton, owner: term.PointerOwner, primary_supported: bool) bool {
    return primary_supported and raw.button == .middle and raw.action == .press and owner == .user;
}

// ---------------------------------------------------------------------------
// Input methods
// ---------------------------------------------------------------------------

/// The text echo SDL sends after a printable key Conduit already encoded.
///
/// One physical printable keystroke reaches the app twice: SDL emits the key
/// event, then a `text_input` event carrying the same character. The key path
/// stays authoritative because only it carries the modifiers the encoder needs
/// (Alt+x as ESC x, kitty-style sequences), so the echo must be dropped rather
/// than committed, or `hello` reaches the child as `hheelllloo`.
///
/// The record is deliberately narrow: only the UTF-8 of the one character the
/// immediately preceding terminal press or repeat encoded, and only until the
/// next key event of any kind or any preedit. Text that differs (an input
/// method commit, a dead-key result, synthetic test-driver text with no key
/// before it) is never touched.
///
/// Ownership: the value owns its four-byte buffer; it borrows nothing.
pub const KeyTextEcho = struct {
    buffer: [4]u8 = undefined,
    len: u8 = 0,

    /// Observe one platform event before it is routed. Returns true when the
    /// event is the expected echo and must be dropped. Every key event and
    /// every preedit clears the record, so `recordTerminalPress` must be
    /// called after this for the key event that is being routed.
    pub fn filter(self: *KeyTextEcho, event: platform.Event) bool {
        switch (event) {
            .key, .text_editing => self.len = 0,
            .text_input => |text| {
                const pending = self.buffer[0..self.len];
                self.len = 0;
                return pending.len != 0 and std.mem.eql(u8, pending, text);
            },
            else => {},
        }
        return false;
    }

    /// Remember the character a key press or repeat sent to the terminal.
    ///
    /// Ctrl and Super chords produce control bytes or sequences rather than
    /// text, so they record nothing. Alt records the bare character because
    /// SDL echoes `x` even though the encoder sent ESC x.
    pub fn recordTerminalPress(self: *KeyTextEcho, raw: platform.KeyEvent, press: Press) void {
        self.len = 0;
        if (press.encoded.composing) return;
        self.recordKeyText(raw, press.encoded.text);
    }

    /// Remember the text a key press or repeat inserted into a focused UI
    /// `Input`. SDL echoes it exactly as it does for the terminal, and an
    /// `Input` would otherwise insert the character twice.
    pub fn recordKeyText(self: *KeyTextEcho, raw: platform.KeyEvent, text: []const u8) void {
        self.len = 0;
        if (raw.action == .release or raw.mods.ctrl or raw.mods.super) return;
        if (text.len == 0 or text.len > self.buffer.len) return;
        @memcpy(self.buffer[0..text.len], text);
        self.len = @intCast(text.len);
    }
};

/// What an input method is composing, and what it last committed.
///
/// An input method (ibus, fcitx, the macOS and Windows ones) does not deliver
/// text when a key is pressed. It delivers a *preedit* — the text as it stands,
/// which the user sees and can move a selection through — and then, when the
/// user commits, the finished text. Conduit's whole job here is to hold the
/// preedit for the renderer and to hand the committed text to the child, and to
/// be wrong about neither.
///
/// It allocates nothing: the preedit is copied into a buffer this value owns,
/// because SDL's copy of it dies with the event and a renderer draws it a frame
/// later. A preedit longer than `max_preedit` is truncated and `truncated`
/// says so — an input method is external input, and a length it chose is not a
/// length Conduit has to be able to hold.
///
/// Ownership: the struct owns its buffer. The preedit it hands out borrows it
/// until the next `update`.
pub const Composition = struct {
    /// The longest preedit held, in bytes. A Japanese preedit of thirty
    /// characters is ninety bytes; this is generous for one and bounded for all.
    pub const max_preedit = 512;

    storage: [max_preedit]u8 = @splat(0),
    len: usize = 0,
    /// The byte offset the selection starts at, within the preedit.
    start: usize = 0,
    /// How many bytes of the preedit are selected.
    selected: usize = 0,
    /// Whether the last preedit was longer than this value can hold.
    truncated: bool = false,
    /// The alternatives the input method is offering.
    candidates: platform.Candidates = .{},

    /// The preedit as it stands, borrowed from this value.
    pub fn preedit(self: *const Composition) []const u8 {
        return self.storage[0..self.len];
    }

    /// Whether an input method is composing right now, which is what makes a
    /// key press display-only.
    pub fn isComposing(self: *const Composition) bool {
        return self.len != 0;
    }

    /// The selected range of the preedit, in reading order.
    pub fn selection(self: *const Composition) platform.TextEditing {
        return .{
            .text = self.preedit(),
            .start = @intCast(self.start),
            .length = @intCast(self.selected),
        };
    }

    /// The candidates the input method is offering, borrowed from this value.
    pub fn offered(self: *const Composition) platform.Candidates {
        return self.candidates;
    }

    /// Record a new preedit from an input method.
    ///
    /// `editing` carries the text and the selection as the input method
    /// reported them, already clamped to the text by `platform`. The copy into
    /// this value is the whole reason the value exists: the renderer reads the
    /// preedit a frame later, long after the SDL event that carried it has been
    /// reused.
    pub fn update(self: *Composition, editing: platform.TextEditing) void {
        const kept = @min(editing.text.len, max_preedit);
        self.truncated = kept != editing.text.len;
        @memcpy(self.storage[0..kept], editing.text[0..kept]);
        self.len = kept;
        self.start = @min(@as(usize, editing.start), kept);
        self.selected = @min(@as(usize, editing.length), kept - self.start);
    }

    /// Record a new candidate list from an input method.
    pub fn setCandidates(self: *Composition, candidates: platform.Candidates) void {
        self.candidates = candidates;
    }

    /// End the composition, because an input method committed.
    ///
    /// This is the commit path: the preedit is gone from the screen and the
    /// committed text is the child's, and the two must not both be true. Called
    /// with the text the input method committed, this hands back what to write
    /// to the child and clears everything the renderer was showing.
    pub fn commit(self: *Composition, committed: []const u8) []const u8 {
        self.len = 0;
        self.start = 0;
        self.selected = 0;
        self.truncated = false;
        self.candidates = .{};
        // The text is the input method's own, and it is borrowed rather than
        // copied: the caller writes it to the child in the same iteration it
        // took it, before the next SDL call can reuse the buffer. Copying it
        // into this value would mean a second buffer for no gain and a
        // truncation rule an input method could hit for no reason.
        return committed;
    }

    /// End the composition without committing anything, because the user
    /// cancelled it.
    pub fn cancel(self: *Composition) void {
        self.len = 0;
        self.start = 0;
        self.selected = 0;
        self.truncated = false;
        self.candidates = .{};
    }
};

test "action registry validates definitions and preserves registration order" {
    const testing = std.testing;
    const Handlers = struct {
        fn noOp(_: *anyopaque, _: Invocation) anyerror!void {}
    };

    var storage: [2]ActionDefinition = undefined;
    var registry = Registry.init(&storage);
    var context: u8 = 0;

    try registry.register(.{ .name = "workspace.new", .label = "New workspace", .handler = Handlers.noOp });
    try registry.register(.{ .name = "clipboard.copy", .label = "Copy", .handler = Handlers.noOp });

    const definitions = registry.definitions();
    try testing.expectEqual(@as(usize, 2), definitions.len);
    try testing.expectEqualStrings("workspace.new", definitions[0].name);
    try testing.expectEqualStrings("clipboard.copy", definitions[1].name);
    try testing.expect(registry.lookup("workspace.new") == &definitions[0]);
    try testing.expect(registry.lookup("missing") == null);
    try testing.expectError(error.DuplicateAction, registry.register(.{
        .name = "workspace.new",
        .label = "Duplicate",
        .handler = Handlers.noOp,
    }));
    try testing.expectError(error.RegistryFull, registry.register(.{
        .name = "workspace.close",
        .label = "Close workspace",
        .handler = Handlers.noOp,
    }));
    try testing.expectError(error.UnknownAction, registry.invoke(&context, "missing", .{ .source = .palette }));

    var invalid_storage: [4]ActionDefinition = undefined;
    var invalid = Registry.init(&invalid_storage);
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "",
        .label = "Empty name",
        .handler = Handlers.noOp,
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad\nname",
        .label = "Control",
        .handler = Handlers.noOp,
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad\xff",
        .label = "Malformed",
        .handler = Handlers.noOp,
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "valid.name",
        .label = "",
        .handler = Handlers.noOp,
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "valid.name",
        .label = "bad\x7f label",
        .handler = Handlers.noOp,
    }));
    try testing.expectEqual(@as(usize, 0), invalid.definitions().len);
}

test "action registry validates and retains borrowed palette metadata" {
    const testing = std.testing;
    const Handlers = struct {
        fn noOp(_: *anyopaque, _: Invocation) anyerror!void {}
    };
    const choices = [_]PaletteChoice{
        .{ .label = "Right", .value = "right" },
        .{ .label = "Down", .value = "down" },
    };

    var storage: [4]ActionDefinition = undefined;
    var registry = Registry.init(&storage);
    try registry.register(.{ .name = "plain", .label = "Plain", .handler = Handlers.noOp });
    try registry.register(.{
        .name = "named.input",
        .label = "Named input",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .input = .{ .name = "title", .prompt = "Tab name" } } },
    });
    try registry.register(.{
        .name = "fixed.choices",
        .label = "Fixed choices",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "Split direction",
            .values = &choices,
        } } },
    });
    try registry.register(.{
        .name = "semantic.internal",
        .label = "Internal",
        .handler = Handlers.noOp,
        .palette = null,
    });

    const definitions = registry.definitions();
    try testing.expect(definitions[0].palette != null);
    try testing.expectEqual(std.meta.Tag(PaletteArgument).none, std.meta.activeTag(definitions[0].palette.?.argument));
    switch (definitions[1].palette.?.argument) {
        .input => |argument| {
            try testing.expectEqualStrings("title", argument.name);
            try testing.expectEqualStrings("Tab name", argument.prompt);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (definitions[2].palette.?.argument) {
        .choices => |argument| {
            try testing.expectEqualStrings("direction", argument.name);
            try testing.expectEqualStrings("Split direction", argument.prompt);
            try testing.expect(argument.values.ptr == choices[0..].ptr);
            try testing.expectEqualStrings("Down", argument.values[1].label);
            try testing.expectEqualStrings("down", argument.values[1].value);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expect(definitions[3].palette == null);

    const duplicate_labels = [_]PaletteChoice{
        .{ .label = "Same", .value = "one" },
        .{ .label = "Same", .value = "two" },
    };
    const duplicate_values = [_]PaletteChoice{
        .{ .label = "One", .value = "same" },
        .{ .label = "Two", .value = "same" },
    };
    const empty_label = [_]PaletteChoice{.{ .label = "", .value = "empty-label" }};
    const malformed_value = [_]PaletteChoice{.{ .label = "Bad value", .value = "bad\xff" }};
    var invalid_storage: [1]ActionDefinition = undefined;
    var invalid = Registry.init(&invalid_storage);
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.input-name",
        .label = "Bad input name",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .input = .{ .name = "", .prompt = "Prompt" } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.input-prompt",
        .label = "Bad input prompt",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .input = .{ .name = "value", .prompt = "bad\nprompt" } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.empty-choices",
        .label = "No choices",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "Direction",
            .values = &.{},
        } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.choice-name",
        .label = "Bad choice name",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "",
            .prompt = "Direction",
            .values = &choices,
        } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.choice-prompt",
        .label = "Bad choice prompt",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "bad\tprompt",
            .values = &choices,
        } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.choice-label",
        .label = "Bad choice label",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "Direction",
            .values = &empty_label,
        } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.choice-value",
        .label = "Bad choice value",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "Direction",
            .values = &malformed_value,
        } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.choice-labels",
        .label = "Duplicate choice labels",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "Direction",
            .values = &duplicate_labels,
        } } },
    }));
    try testing.expectError(error.InvalidDefinition, invalid.register(.{
        .name = "bad.choice-values",
        .label = "Duplicate choice values",
        .handler = Handlers.noOp,
        .palette = .{ .argument = .{ .choices = .{
            .name = "direction",
            .prompt = "Direction",
            .values = &duplicate_values,
        } } },
    }));
    try testing.expectEqual(@as(usize, 0), invalid.definitions().len);
}

test "one action handler receives every invocation source origin and named arguments" {
    const testing = std.testing;
    const Witness = struct {
        calls: usize = 0,
        sources: [3]InvocationSource = undefined,

        fn handle(context: *anyopaque, invocation: Invocation) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expect(self.calls < self.sources.len);
            self.sources[self.calls] = invocation.source;
            self.calls += 1;
            try std.testing.expectEqualStrings("ui-test.action", invocation.origin.?.value);
            try std.testing.expectEqual(@as(usize, 2), invocation.arguments.len);
            try std.testing.expectEqualStrings("mode", invocation.arguments[0].name);
            try std.testing.expectEqualStrings("safe", invocation.arguments[0].value);
            try std.testing.expectEqualStrings("target", invocation.arguments[1].name);
            try std.testing.expectEqualStrings("terminal", invocation.arguments[1].value);
        }
    };

    var storage: [1]ActionDefinition = undefined;
    var registry = Registry.init(&storage);
    try registry.register(.{ .name = "test.invoke", .label = "Invoke", .handler = Witness.handle });
    var witness: Witness = .{};
    const origin = try ui.Id.parse("ui-test.action");
    const arguments = [_]Argument{
        .{ .name = "mode", .value = "safe" },
        .{ .name = "target", .value = "terminal" },
    };

    for ([_]InvocationSource{ .keybinding, .mouse, .palette }) |source| {
        try registry.invoke(&witness, "test.invoke", .{
            .source = source,
            .origin = origin,
            .arguments = &arguments,
        });
    }

    try testing.expectEqual(@as(usize, 3), witness.calls);
    try testing.expectEqual(InvocationSource.keybinding, witness.sources[0]);
    try testing.expectEqual(InvocationSource.mouse, witness.sources[1]);
    try testing.expectEqual(InvocationSource.palette, witness.sources[2]);
}

test "action registry rejects invalid invocation metadata and propagates handler errors" {
    const testing = std.testing;
    const Handlers = struct {
        fn count(context: *anyopaque, _: Invocation) anyerror!void {
            const calls: *usize = @ptrCast(@alignCast(context));
            calls.* += 1;
        }

        fn fail(_: *anyopaque, _: Invocation) anyerror!void {
            return error.HandlerFailure;
        }
    };

    var storage: [2]ActionDefinition = undefined;
    var registry = Registry.init(&storage);
    try registry.register(.{ .name = "test.count", .label = "Count", .handler = Handlers.count });
    try registry.register(.{ .name = "test.fail", .label = "Fail", .handler = Handlers.fail });
    var calls: usize = 0;

    try testing.expectError(error.InvalidInvocation, registry.invoke(&calls, "test.count", .{
        .source = .palette,
        .arguments = &.{.{ .name = "", .value = "value" }},
    }));
    try testing.expectError(error.InvalidInvocation, registry.invoke(&calls, "test.count", .{
        .source = .palette,
        .arguments = &.{.{ .name = "name", .value = "bad\nvalue" }},
    }));
    try testing.expectError(error.InvalidInvocation, registry.invoke(&calls, "test.count", .{
        .source = .mouse,
        .origin = .{ .value = "bad id" },
    }));
    try testing.expectEqual(@as(usize, 0), calls);
    try testing.expectError(error.HandlerFailure, registry.invoke(&calls, "test.fail", .{ .source = .keybinding }));
}

test "platform profiles preserve existing defaults before pane bindings" {
    const testing = std.testing;
    const macos = defaultBindings(.macos);
    const linux_windows = defaultBindings(.linux_windows);

    try testing.expectEqual(@as(usize, 44), macos.len);
    try testing.expectEqualStrings("clipboard.copy", macos[0].action);
    try testing.expect(bindingKeyEql(.{ .character = 'c' }, macos[0].chord.key));
    try testing.expectEqual(Modifiers{ .super = true }, macos[0].chord.modifiers);
    try testing.expectEqualStrings("clipboard.paste", macos[1].action);
    try testing.expect(bindingKeyEql(.{ .character = 'v' }, macos[1].chord.key));
    try testing.expectEqual(Modifiers{ .super = true }, macos[1].chord.modifiers);
    try testing.expectEqualStrings("sidebar.toggle", macos[2].action);
    try testing.expect(bindingKeyEql(.{ .character = 'b' }, macos[2].chord.key));
    try testing.expectEqual(Modifiers{ .shift = true, .super = true }, macos[2].chord.modifiers);
    try testing.expectEqualStrings("sidebar.narrow", macos[3].action);
    try testing.expect(bindingKeyEql(.{ .named = .left }, macos[3].chord.key));
    try testing.expectEqual(Modifiers{ .shift = true, .super = true }, macos[3].chord.modifiers);
    try testing.expectEqualStrings("sidebar.widen", macos[4].action);
    try testing.expect(bindingKeyEql(.{ .named = .right }, macos[4].chord.key));
    try testing.expectEqual(Modifiers{ .shift = true, .super = true }, macos[4].chord.modifiers);
    try testing.expectEqualStrings("sidebar.focus", macos[5].action);
    try testing.expect(bindingKeyEql(.{ .named = .down }, macos[5].chord.key));
    try testing.expectEqual(Modifiers{ .shift = true, .super = true }, macos[5].chord.modifiers);
    try testing.expectEqualStrings("scratchpad.toggle-50", macos[34].action);
    try testing.expect(bindingKeyEql(.{ .character = '`' }, macos[34].chord.key));
    try testing.expectEqual(Modifiers{ .super = true }, macos[34].chord.modifiers);
    try testing.expectEqualStrings("scratchpad.toggle-90", macos[35].action);
    try testing.expect(bindingKeyEql(.{ .character = '`' }, macos[35].chord.key));
    try testing.expectEqual(Modifiers{ .shift = true, .super = true }, macos[35].chord.modifiers);
    try testing.expectEqualStrings("palette.open", macos[36].action);
    try testing.expect(bindingKeyEql(.{ .character = 'p' }, macos[36].chord.key));
    try testing.expectEqual(Modifiers{ .shift = true, .super = true }, macos[36].chord.modifiers);

    try testing.expectEqual(@as(usize, 44), linux_windows.len);
    try testing.expectEqualStrings("clipboard.copy", linux_windows[0].action);
    try testing.expect(bindingKeyEql(.{ .character = 'c' }, linux_windows[0].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[0].chord.modifiers);
    try testing.expectEqualStrings("clipboard.paste", linux_windows[1].action);
    try testing.expect(bindingKeyEql(.{ .character = 'v' }, linux_windows[1].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[1].chord.modifiers);
    try testing.expectEqualStrings("sidebar.toggle", linux_windows[2].action);
    try testing.expect(bindingKeyEql(.{ .character = 'b' }, linux_windows[2].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[2].chord.modifiers);
    try testing.expectEqualStrings("sidebar.narrow", linux_windows[3].action);
    try testing.expect(bindingKeyEql(.{ .named = .left }, linux_windows[3].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[3].chord.modifiers);
    try testing.expectEqualStrings("sidebar.widen", linux_windows[4].action);
    try testing.expect(bindingKeyEql(.{ .named = .right }, linux_windows[4].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[4].chord.modifiers);
    try testing.expectEqualStrings("sidebar.focus", linux_windows[5].action);
    try testing.expect(bindingKeyEql(.{ .named = .down }, linux_windows[5].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[5].chord.modifiers);
    try testing.expectEqualStrings("scratchpad.toggle-50", linux_windows[34].action);
    try testing.expect(bindingKeyEql(.{ .character = '`' }, linux_windows[34].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true }, linux_windows[34].chord.modifiers);
    try testing.expectEqualStrings("scratchpad.toggle-90", linux_windows[35].action);
    try testing.expect(bindingKeyEql(.{ .character = '`' }, linux_windows[35].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[35].chord.modifiers);
    try testing.expectEqualStrings("palette.open", linux_windows[36].action);
    try testing.expect(bindingKeyEql(.{ .character = 'p' }, linux_windows[36].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true, .shift = true }, linux_windows[36].chord.modifiers);
    try testing.expectEqualStrings("config.open", macos[38].action);
    try testing.expect(bindingKeyEql(.{ .character = ',' }, macos[38].chord.key));
    try testing.expectEqual(Modifiers{ .super = true }, macos[38].chord.modifiers);
    try testing.expectEqualStrings("config.open", linux_windows[38].action);
    try testing.expect(bindingKeyEql(.{ .character = ',' }, linux_windows[38].chord.key));
    try testing.expectEqual(Modifiers{ .ctrl = true }, linux_windows[38].chord.modifiers);
    for ([_][]const Binding{ &macos_default_bindings, &linux_windows_default_bindings }) |table| {
        try testing.expectEqualStrings("font.size.increase", table[39].action);
        try testing.expectEqualStrings("font.size.increase", table[40].action);
        try testing.expectEqualStrings("font.size.decrease", table[41].action);
        try testing.expectEqualStrings("font.size.reset", table[42].action);
        try testing.expectEqualStrings("settings.open", table[43].action);
        try testing.expect(bindingKeyEql(.{ .character = ',' }, table[43].chord.key));
        try testing.expect(table[43].chord.modifiers.shift);
    }
    try testing.expectEqual(@as(usize, 0), macos[0].arguments.len);
    try testing.expectEqual(@as(usize, 0), linux_windows[0].arguments.len);
    try testing.expectEqual(
        if (builtin.os.tag == .macos) PlatformProfile.macos else PlatformProfile.linux_windows,
        PlatformProfile.native,
    );
}

fn expectDefaultAction(
    profile: PlatformProfile,
    raw: platform.KeyEvent,
    expected_action: []const u8,
    expected_argument: ?Argument,
) !void {
    const testing = std.testing;
    var scratch: TextScratch = .{};
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    switch (resolve(&state, raw, translate(&scratch, raw, false), defaultBindings(profile))) {
        .action => |request| {
            try testing.expectEqualStrings(expected_action, request.action);
            try testing.expectEqual(InvocationSource.keybinding, request.invocation.source);
            try testing.expect(request.invocation.origin == null);
            if (expected_argument) |argument| {
                try testing.expectEqual(@as(usize, 1), request.invocation.arguments.len);
                try testing.expectEqualStrings(argument.name, request.invocation.arguments[0].name);
                try testing.expectEqualStrings(argument.value, request.invocation.arguments[0].value);
            } else {
                try testing.expectEqual(@as(usize, 0), request.invocation.arguments.len);
            }
        },
        else => return error.TestUnexpectedResult,
    }
}

fn expectDefaultTerminal(profile: PlatformProfile, raw: platform.KeyEvent) !void {
    var scratch: TextScratch = .{};
    const translated = translate(&scratch, raw, false);
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    switch (resolve(&state, raw, translated, defaultBindings(profile))) {
        .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }
}

/// A transition of the physical backtick key. SDL reports the shifted glyph as
/// tilde while retaining backtick as the layout-independent binding identity.
fn backtickKey(mods: platform.Mods, action: platform.KeyAction) platform.KeyEvent {
    return .{
        .action = action,
        .key = .unidentified,
        .mods = mods,
        .codepoint = if (mods.shift) '~' else '`',
        .unshifted_codepoint = '`',
    };
}

fn symbolKey(codepoint: u21, shifted: u21, mods: platform.Mods) platform.KeyEvent {
    return .{
        .action = .press,
        .key = .unidentified,
        .mods = mods,
        .codepoint = if (mods.shift) shifted else codepoint,
        .unshifted_codepoint = codepoint,
    };
}

test "font size defaults zoom with the platform modifier and leave the plain keys to the terminal" {
    const cases = [_]struct { profile: PlatformProfile, raw: platform.KeyEvent, action: []const u8 }{
        .{ .profile = .linux_windows, .raw = symbolKey('=', '+', .{ .ctrl = true }), .action = "font.size.increase" },
        .{ .profile = .linux_windows, .raw = symbolKey('=', '+', .{ .ctrl = true, .shift = true }), .action = "font.size.increase" },
        .{ .profile = .linux_windows, .raw = symbolKey('-', '_', .{ .ctrl = true }), .action = "font.size.decrease" },
        .{ .profile = .linux_windows, .raw = symbolKey('0', ')', .{ .ctrl = true }), .action = "font.size.reset" },
        .{ .profile = .macos, .raw = symbolKey('=', '+', .{ .super = true }), .action = "font.size.increase" },
        .{ .profile = .macos, .raw = symbolKey('=', '+', .{ .shift = true, .super = true }), .action = "font.size.increase" },
        .{ .profile = .macos, .raw = symbolKey('-', '_', .{ .super = true }), .action = "font.size.decrease" },
        .{ .profile = .macos, .raw = symbolKey('0', ')', .{ .super = true }), .action = "font.size.reset" },
    };
    for (cases) |case| try expectDefaultAction(case.profile, case.raw, case.action, null);

    for ([_]PlatformProfile{ .linux_windows, .macos }) |profile| {
        try expectDefaultTerminal(profile, symbolKey('=', '+', .{}));
        try expectDefaultTerminal(profile, symbolKey('-', '_', .{}));
        try expectDefaultTerminal(profile, symbolKey('0', ')', .{}));
        try expectDefaultTerminal(profile, symbolKey('=', '+', .{ .shift = true }));
        try expectDefaultTerminal(profile, symbolKey('-', '_', .{ .alt = true }));
    }
    // Ctrl+Shift+- (Ctrl+_) stays the terminal's on Linux and Windows: it is a C0 control.
    try expectDefaultTerminal(.linux_windows, symbolKey('-', '_', .{ .ctrl = true, .shift = true }));
}

test "the settings view opens with Shift added to the config file chord and the near misses stay the terminal's" {
    try expectDefaultAction(.linux_windows, symbolKey(',', '<', .{ .ctrl = true, .shift = true }), "settings.open", null);
    try expectDefaultAction(.macos, symbolKey(',', '<', .{ .shift = true, .super = true }), "settings.open", null);
    try expectDefaultAction(.linux_windows, symbolKey(',', '<', .{ .ctrl = true }), "config.open", null);
    try expectDefaultAction(.macos, symbolKey(',', '<', .{ .super = true }), "config.open", null);
    for ([_]PlatformProfile{ .linux_windows, .macos }) |profile| {
        try expectDefaultTerminal(profile, symbolKey(',', '<', .{ .shift = true }));
        try expectDefaultTerminal(profile, symbolKey(',', '<', .{ .alt = true, .shift = true }));
    }
}

test "tab defaults route exact platform actions and static arguments" {
    const no_argument_cases = [_]struct {
        profile: PlatformProfile,
        raw: platform.KeyEvent,
        action: []const u8,
    }{
        .{ .profile = .macos, .raw = letterKey('t', .{ .super = true }, .press), .action = "tab.new" },
        .{ .profile = .macos, .raw = letterKey('w', .{ .super = true }, .press), .action = "tab.close" },
        .{ .profile = .macos, .raw = .{ .action = .press, .key = .f2 }, .action = "tab.rename" },
        .{ .profile = .macos, .raw = letterKey('[', .{ .shift = true, .super = true }, .press), .action = "tab.previous" },
        .{ .profile = .macos, .raw = letterKey(']', .{ .shift = true, .super = true }, .press), .action = "tab.next" },
        .{ .profile = .linux_windows, .raw = letterKey('t', .{ .ctrl = true, .shift = true }, .press), .action = "tab.new" },
        .{ .profile = .linux_windows, .raw = letterKey('w', .{ .ctrl = true, .shift = true }, .press), .action = "tab.close" },
        .{ .profile = .linux_windows, .raw = .{ .action = .press, .key = .f2 }, .action = "tab.rename" },
        .{ .profile = .linux_windows, .raw = .{ .action = .press, .key = .page_up, .mods = .{ .ctrl = true } }, .action = "tab.previous" },
        .{ .profile = .linux_windows, .raw = .{ .action = .press, .key = .page_down, .mods = .{ .ctrl = true } }, .action = "tab.next" },
    };
    for (no_argument_cases) |case| {
        try expectDefaultAction(case.profile, case.raw, case.action, null);
    }

    for ([_]PlatformProfile{ .macos, .linux_windows }) |profile| {
        const goto_mods: platform.Mods = switch (profile) {
            .macos => .{ .super = true },
            .linux_windows => .{ .alt = true },
        };
        for ("123456789", 0..) |digit, index| {
            const value = "123456789"[index .. index + 1];
            try expectDefaultAction(
                profile,
                letterKey(digit, goto_mods, .press),
                "tab.goto",
                .{ .name = "index", .value = value },
            );
        }

        try expectDefaultAction(
            profile,
            .{ .action = .press, .key = .up, .mods = .{ .alt = true, .shift = true } },
            "tab.move",
            .{ .name = "direction", .value = "up" },
        );
        try expectDefaultAction(
            profile,
            .{ .action = .press, .key = .down, .mods = .{ .alt = true, .shift = true } },
            "tab.move",
            .{ .name = "direction", .value = "down" },
        );
    }
}

test "tab binding near misses and unrelated keys remain terminal owned" {
    const macos_near_misses = [_]platform.KeyEvent{
        letterKey('t', .{ .shift = true, .super = true }, .press),
        letterKey('[', .{ .super = true }, .press),
        letterKey('1', .{ .alt = true }, .press),
        .{ .action = .press, .key = .up, .mods = .{ .super = true } },
        .{ .action = .press, .key = .f2, .mods = .{ .shift = true } },
        letterKey('q', .{}, .press),
    };
    for (macos_near_misses) |raw| try expectDefaultTerminal(.macos, raw);

    const linux_windows_near_misses = [_]platform.KeyEvent{
        letterKey('t', .{ .ctrl = true }, .press),
        .{ .action = .press, .key = .page_up, .mods = .{ .ctrl = true, .shift = true } },
        letterKey('0', .{ .alt = true }, .press),
        .{ .action = .press, .key = .up, .mods = .{ .super = true } },
        .{ .action = .press, .key = .f2, .mods = .{ .ctrl = true } },
        letterKey('q', .{}, .press),
    };
    for (linux_windows_near_misses) |raw| try expectDefaultTerminal(.linux_windows, raw);
}

test "pane defaults route every platform action and direction argument" {
    const directions = [_]struct {
        key: platform.Key,
        value: []const u8,
    }{
        .{ .key = .left, .value = "left" },
        .{ .key = .right, .value = "right" },
        .{ .key = .up, .value = "up" },
        .{ .key = .down, .value = "down" },
    };

    try expectDefaultAction(
        .macos,
        letterKey('d', .{ .super = true }, .press),
        "pane.split",
        .{ .name = "direction", .value = "right" },
    );
    try expectDefaultAction(
        .macos,
        letterKey('d', .{ .shift = true, .super = true }, .press),
        "pane.split",
        .{ .name = "direction", .value = "down" },
    );
    try expectDefaultAction(
        .linux_windows,
        letterKey('e', .{ .ctrl = true, .shift = true }, .press),
        "pane.split",
        .{ .name = "direction", .value = "right" },
    );
    try expectDefaultAction(
        .linux_windows,
        letterKey('o', .{ .ctrl = true, .shift = true }, .press),
        "pane.split",
        .{ .name = "direction", .value = "down" },
    );

    for (directions) |direction| {
        try expectDefaultAction(
            .macos,
            .{ .action = .press, .key = direction.key, .mods = .{ .alt = true, .super = true } },
            "pane.focus",
            .{ .name = "direction", .value = direction.value },
        );
        try expectDefaultAction(
            .macos,
            .{ .action = .press, .key = direction.key, .mods = .{ .ctrl = true, .super = true } },
            "pane.resize",
            .{ .name = "direction", .value = direction.value },
        );
        try expectDefaultAction(
            .linux_windows,
            .{ .action = .press, .key = direction.key, .mods = .{ .alt = true } },
            "pane.focus",
            .{ .name = "direction", .value = direction.value },
        );
        try expectDefaultAction(
            .linux_windows,
            .{ .action = .press, .key = direction.key, .mods = .{ .ctrl = true, .alt = true } },
            "pane.resize",
            .{ .name = "direction", .value = direction.value },
        );
    }

    try expectDefaultAction(
        .macos,
        .{ .action = .press, .key = .enter, .mods = .{ .shift = true, .super = true } },
        "pane.zoom",
        null,
    );
    try expectDefaultAction(
        .macos,
        letterKey('x', .{ .shift = true, .super = true }, .press),
        "pane.close",
        null,
    );
    try expectDefaultAction(
        .linux_windows,
        .{ .action = .press, .key = .enter, .mods = .{ .ctrl = true, .shift = true } },
        "pane.zoom",
        null,
    );
    try expectDefaultAction(
        .linux_windows,
        letterKey('x', .{ .ctrl = true, .shift = true }, .press),
        "pane.close",
        null,
    );
}

test "pane near misses remain exact terminal input" {
    const macos_near_misses = [_]platform.KeyEvent{
        letterKey('d', .{ .alt = true, .super = true }, .press),
        letterKey('e', .{ .shift = true, .super = true }, .press),
        .{ .action = .press, .key = .left, .mods = .{ .super = true } },
        .{ .action = .press, .key = .right, .mods = .{ .alt = true, .shift = true, .super = true } },
        .{ .action = .press, .key = .enter, .mods = .{ .ctrl = true, .shift = true, .super = true } },
        letterKey('x', .{ .super = true }, .press),
        .{ .action = .press, .key = .up },
    };
    for (macos_near_misses) |raw| try expectDefaultTerminal(.macos, raw);

    const linux_windows_near_misses = [_]platform.KeyEvent{
        letterKey('d', .{ .ctrl = true, .shift = true }, .press),
        letterKey('e', .{ .ctrl = true, .alt = true, .shift = true }, .press),
        .{ .action = .press, .key = .left, .mods = .{ .ctrl = true } },
        .{ .action = .press, .key = .right, .mods = .{ .ctrl = true, .alt = true, .shift = true } },
        .{ .action = .press, .key = .enter, .mods = .{ .alt = true } },
        letterKey('x', .{ .ctrl = true }, .press),
        .{ .action = .press, .key = .up },
    };
    for (linux_windows_near_misses) |raw| try expectDefaultTerminal(.linux_windows, raw);
}

test "scratchpad defaults route both presentation actions from the physical backtick key" {
    const cases = [_]struct {
        profile: PlatformProfile,
        mods: platform.Mods,
        action: []const u8,
    }{
        .{ .profile = .macos, .mods = .{ .super = true }, .action = "scratchpad.toggle-50" },
        .{ .profile = .macos, .mods = .{ .shift = true, .super = true }, .action = "scratchpad.toggle-90" },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true }, .action = "scratchpad.toggle-50" },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true, .shift = true }, .action = "scratchpad.toggle-90" },
    };

    for (cases) |case| {
        try expectDefaultAction(case.profile, backtickKey(case.mods, .press), case.action, null);
    }
}

test "scratchpad binding ownership consumes repeat and modifier-order release" {
    const cases = [_]struct {
        profile: PlatformProfile,
        mods: platform.Mods,
        action: []const u8,
    }{
        .{ .profile = .macos, .mods = .{ .super = true }, .action = "scratchpad.toggle-50" },
        .{ .profile = .macos, .mods = .{ .shift = true, .super = true }, .action = "scratchpad.toggle-90" },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true }, .action = "scratchpad.toggle-50" },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true, .shift = true }, .action = "scratchpad.toggle-90" },
    };

    for (cases) |case| {
        var scratch: TextScratch = .{};
        var binding_storage: [1]BindingKey = undefined;
        var state = BindingState.init(&binding_storage);
        const bindings = defaultBindings(case.profile);

        const press = backtickKey(case.mods, .press);
        switch (resolve(&state, press, translate(&scratch, press, false), bindings)) {
            .action => |request| {
                try std.testing.expectEqualStrings(case.action, request.action);
                try std.testing.expectEqual(InvocationSource.keybinding, request.invocation.source);
                try std.testing.expectEqual(@as(usize, 0), request.invocation.arguments.len);
            },
            else => return error.TestUnexpectedResult,
        }

        const repeat = backtickKey(.{}, .repeat);
        switch (resolve(&state, repeat, translate(&scratch, repeat, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const release = backtickKey(.{}, .release);
        switch (resolve(&state, release, translate(&scratch, release, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const unowned_repeat = backtickKey(case.mods, .repeat);
        const translated = translate(&scratch, unowned_repeat, false);
        switch (resolve(&state, unowned_repeat, translated, bindings)) {
            .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "scratchpad near misses and a different unshifted identity remain terminal owned" {
    const macos_near_misses = [_]platform.KeyEvent{
        backtickKey(.{}, .press),
        backtickKey(.{ .ctrl = true }, .press),
        backtickKey(.{ .alt = true, .super = true }, .press),
        .{ .action = .press, .mods = .{ .shift = true, .super = true }, .codepoint = '~', .unshifted_codepoint = '~' },
    };
    for (macos_near_misses) |raw| try expectDefaultTerminal(.macos, raw);

    const linux_windows_near_misses = [_]platform.KeyEvent{
        backtickKey(.{}, .press),
        backtickKey(.{ .super = true }, .press),
        backtickKey(.{ .ctrl = true, .alt = true }, .press),
        .{ .action = .press, .mods = .{ .ctrl = true, .shift = true }, .codepoint = '~', .unshifted_codepoint = '~' },
    };
    for (linux_windows_near_misses) |raw| try expectDefaultTerminal(.linux_windows, raw);
}

test "palette open defaults dispatch once and own repeat and release on both profiles" {
    const cases = [_]struct {
        profile: PlatformProfile,
        mods: platform.Mods,
    }{
        .{ .profile = .macos, .mods = .{ .shift = true, .super = true } },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true, .shift = true } },
    };

    for (cases) |case| {
        var scratch: TextScratch = .{};
        var binding_storage: [1]BindingKey = undefined;
        var state = BindingState.init(&binding_storage);
        const bindings = defaultBindings(case.profile);

        const press = letterKey('p', case.mods, .press);
        switch (resolve(&state, press, translate(&scratch, press, false), bindings)) {
            .action => |request| {
                try std.testing.expectEqualStrings("palette.open", request.action);
                try std.testing.expectEqual(InvocationSource.keybinding, request.invocation.source);
                try std.testing.expect(request.invocation.origin == null);
                try std.testing.expectEqual(@as(usize, 0), request.invocation.arguments.len);
            },
            else => return error.TestUnexpectedResult,
        }

        const repeat = letterKey('p', .{}, .repeat);
        switch (resolve(&state, repeat, translate(&scratch, repeat, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const release = letterKey('p', .{}, .release);
        switch (resolve(&state, release, translate(&scratch, release, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const unowned_repeat = letterKey('p', case.mods, .repeat);
        const translated = translate(&scratch, unowned_repeat, false);
        switch (resolve(&state, unowned_repeat, translated, bindings)) {
            .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "palette open near misses preserve exact terminal fallback" {
    const macos_near_misses = [_]platform.KeyEvent{
        letterKey('p', .{ .super = true }, .press),
        letterKey('p', .{ .ctrl = true, .shift = true }, .press),
        letterKey('p', .{ .alt = true, .shift = true, .super = true }, .press),
        letterKey('q', .{ .shift = true, .super = true }, .press),
    };
    for (macos_near_misses) |raw| try expectDefaultTerminal(.macos, raw);

    const linux_windows_near_misses = [_]platform.KeyEvent{
        letterKey('p', .{ .ctrl = true }, .press),
        letterKey('p', .{ .shift = true, .super = true }, .press),
        letterKey('p', .{ .ctrl = true, .alt = true, .shift = true }, .press),
        letterKey('q', .{ .ctrl = true, .shift = true }, .press),
    };
    for (linux_windows_near_misses) |raw| try expectDefaultTerminal(.linux_windows, raw);
}

test "context menu defaults route Shift+F10 on both profiles and leave plain F10 to the terminal" {
    for ([_]PlatformProfile{ .macos, .linux_windows }) |profile| {
        try expectDefaultAction(
            profile,
            .{ .action = .press, .key = .f10, .mods = .{ .shift = true } },
            "terminal.context-menu",
            null,
        );
        var scratch: TextScratch = .{};
        var binding_storage: [1]BindingKey = undefined;
        var state = BindingState.init(&binding_storage);
        const plain: platform.KeyEvent = .{ .action = .press, .key = .f10 };
        switch (resolve(&state, plain, translate(&scratch, plain, false), defaultBindings(profile))) {
            .terminal => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "pane arrow chords do not displace tab reorder or sidebar bindings" {
    for ([_]PlatformProfile{ .macos, .linux_windows }) |profile| {
        try expectDefaultAction(
            profile,
            .{ .action = .press, .key = .up, .mods = .{ .alt = true, .shift = true } },
            "tab.move",
            .{ .name = "direction", .value = "up" },
        );
        try expectDefaultAction(
            profile,
            .{ .action = .press, .key = .down, .mods = .{ .alt = true, .shift = true } },
            "tab.move",
            .{ .name = "direction", .value = "down" },
        );
    }

    try expectDefaultAction(
        .macos,
        .{ .action = .press, .key = .left, .mods = .{ .shift = true, .super = true } },
        "sidebar.narrow",
        null,
    );
    try expectDefaultAction(
        .macos,
        .{ .action = .press, .key = .right, .mods = .{ .shift = true, .super = true } },
        "sidebar.widen",
        null,
    );
    try expectDefaultAction(
        .macos,
        .{ .action = .press, .key = .down, .mods = .{ .shift = true, .super = true } },
        "sidebar.focus",
        null,
    );
    try expectDefaultAction(
        .linux_windows,
        .{ .action = .press, .key = .left, .mods = .{ .ctrl = true, .shift = true } },
        "sidebar.narrow",
        null,
    );
    try expectDefaultAction(
        .linux_windows,
        .{ .action = .press, .key = .right, .mods = .{ .ctrl = true, .shift = true } },
        "sidebar.widen",
        null,
    );
    try expectDefaultAction(
        .linux_windows,
        .{ .action = .press, .key = .down, .mods = .{ .ctrl = true, .shift = true } },
        "sidebar.focus",
        null,
    );
}

test "pane arrow ownership consumes repeat and release transitions" {
    const cases = [_]struct {
        profile: PlatformProfile,
        mods: platform.Mods,
        action: []const u8,
    }{
        .{ .profile = .macos, .mods = .{ .alt = true, .super = true }, .action = "pane.focus" },
        .{ .profile = .macos, .mods = .{ .ctrl = true, .super = true }, .action = "pane.resize" },
        .{ .profile = .linux_windows, .mods = .{ .alt = true }, .action = "pane.focus" },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true, .alt = true }, .action = "pane.resize" },
    };

    for (cases) |case| {
        var scratch: TextScratch = .{};
        var binding_storage: [1]BindingKey = undefined;
        var state = BindingState.init(&binding_storage);
        const bindings = defaultBindings(case.profile);

        const press: platform.KeyEvent = .{ .action = .press, .key = .left, .mods = case.mods };
        switch (resolve(&state, press, translate(&scratch, press, false), bindings)) {
            .action => |request| {
                try std.testing.expectEqualStrings(case.action, request.action);
                try std.testing.expectEqualStrings("direction", request.invocation.arguments[0].name);
                try std.testing.expectEqualStrings("left", request.invocation.arguments[0].value);
            },
            else => return error.TestUnexpectedResult,
        }

        const repeat: platform.KeyEvent = .{ .action = .repeat, .key = .left };
        switch (resolve(&state, repeat, translate(&scratch, repeat, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const release: platform.KeyEvent = .{ .action = .release, .key = .left };
        switch (resolve(&state, release, translate(&scratch, release, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const unowned_repeat: platform.KeyEvent = .{ .action = .repeat, .key = .left, .mods = case.mods };
        const translated = translate(&scratch, unowned_repeat, false);
        switch (resolve(&state, unowned_repeat, translated, bindings)) {
            .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "sidebar defaults route their exact actions on both platform profiles" {
    const testing = std.testing;
    const profiles = [_]struct {
        profile: PlatformProfile,
        mods: platform.Mods,
    }{
        .{ .profile = .macos, .mods = .{ .shift = true, .super = true } },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true, .shift = true } },
    };

    for (profiles) |profile| {
        const cases = [_]struct {
            raw: platform.KeyEvent,
            action: []const u8,
        }{
            .{ .raw = letterKey('b', profile.mods, .press), .action = "sidebar.toggle" },
            .{ .raw = .{ .action = .press, .key = .left, .mods = profile.mods }, .action = "sidebar.narrow" },
            .{ .raw = .{ .action = .press, .key = .right, .mods = profile.mods }, .action = "sidebar.widen" },
            .{ .raw = .{ .action = .press, .key = .down, .mods = profile.mods }, .action = "sidebar.focus" },
        };
        for (cases) |case| {
            var scratch: TextScratch = .{};
            var binding_storage: [1]BindingKey = undefined;
            var state = BindingState.init(&binding_storage);
            switch (resolve(
                &state,
                case.raw,
                translate(&scratch, case.raw, false),
                defaultBindings(profile.profile),
            )) {
                .action => |request| {
                    try testing.expectEqualStrings(case.action, request.action);
                    try testing.expectEqual(InvocationSource.keybinding, request.invocation.source);
                },
                else => return error.TestUnexpectedResult,
            }
        }
    }
}

test "sidebar binding ownership consumes repeats and modifier-order releases" {
    const profiles = [_]struct {
        profile: PlatformProfile,
        mods: platform.Mods,
    }{
        .{ .profile = .macos, .mods = .{ .shift = true, .super = true } },
        .{ .profile = .linux_windows, .mods = .{ .ctrl = true, .shift = true } },
    };

    for (profiles) |profile| {
        var scratch: TextScratch = .{};
        var binding_storage: [1]BindingKey = undefined;
        var state = BindingState.init(&binding_storage);
        const bindings = defaultBindings(profile.profile);

        const press: platform.KeyEvent = .{ .action = .press, .key = .left, .mods = profile.mods };
        switch (resolve(&state, press, translate(&scratch, press, false), bindings)) {
            .action => |request| {
                if (!std.mem.eql(u8, request.action, "sidebar.narrow")) {
                    return error.TestUnexpectedResult;
                }
            },
            else => return error.TestUnexpectedResult,
        }

        const repeat: platform.KeyEvent = .{ .action = .repeat, .key = .left, .mods = .{} };
        switch (resolve(&state, repeat, translate(&scratch, repeat, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const release: platform.KeyEvent = .{ .action = .release, .key = .left, .mods = .{} };
        switch (resolve(&state, release, translate(&scratch, release, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }

        const unowned: platform.KeyEvent = .{ .action = .release, .key = .left, .mods = profile.mods };
        const translated = translate(&scratch, unowned, false);
        switch (resolve(&state, unowned, translated, bindings)) {
            .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }

        const plain_down: platform.KeyEvent = .{ .action = .press, .key = .down };
        const plain_down_translated = translate(&scratch, plain_down, false);
        switch (resolve(&state, plain_down, plain_down_translated, bindings)) {
            .terminal => |terminal_press| try expectTerminalPressExact(plain_down_translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "binding resolution uses unshifted letters and exact intent modifiers" {
    const testing = std.testing;
    var scratch: TextScratch = .{};
    const bindings = defaultBindings(.linux_windows);

    var shifted_storage: [2]BindingKey = undefined;
    var shifted_state = BindingState.init(&shifted_storage);
    const shifted = letterKey('c', .{ .ctrl = true, .shift = true }, .press);
    const shifted_route = resolve(&shifted_state, shifted, translate(&scratch, shifted, false), bindings);
    switch (shifted_route) {
        .action => |request| {
            try testing.expectEqualStrings("clipboard.copy", request.action);
            try testing.expectEqual(InvocationSource.keybinding, request.invocation.source);
            try testing.expect(request.invocation.origin == null);
        },
        else => return error.TestUnexpectedResult,
    }

    const locked = letterKey('v', .{
        .ctrl = true,
        .shift = true,
        .caps_lock = true,
        .num_lock = true,
    }, .press);
    var locked_storage: [2]BindingKey = undefined;
    var locked_state = BindingState.init(&locked_storage);
    const locked_route = resolve(&locked_state, locked, translate(&scratch, locked, false), bindings);
    switch (locked_route) {
        .action => |request| try testing.expectEqualStrings("clipboard.paste", request.action),
        else => return error.TestUnexpectedResult,
    }

    const extra = letterKey('c', .{ .ctrl = true, .alt = true, .shift = true }, .press);
    const extra_press = translate(&scratch, extra, false);
    var extra_storage: [2]BindingKey = undefined;
    var extra_state = BindingState.init(&extra_storage);
    const extra_route = resolve(&extra_state, extra, extra_press, bindings);
    switch (extra_route) {
        .terminal => |terminal_press| try expectTerminalPressExact(extra_press.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }
}

test "bound press invokes once while repeat and release are consumed" {
    const testing = std.testing;
    var scratch: TextScratch = .{};
    const bindings = defaultBindings(.linux_windows);
    const mods: platform.Mods = .{ .ctrl = true, .shift = true };
    var binding_storage: [2]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);

    const pressed = letterKey('v', mods, .press);
    switch (resolve(&state, pressed, translate(&scratch, pressed, false), bindings)) {
        .action => |request| try testing.expectEqualStrings("clipboard.paste", request.action),
        else => return error.TestUnexpectedResult,
    }

    for ([_]platform.KeyAction{ .repeat, .release }) |action| {
        const raw = letterKey('v', mods, action);
        switch (resolve(&state, raw, translate(&scratch, raw, false), bindings)) {
            .consumed => {},
            else => return error.TestUnexpectedResult,
        }
    }
}

test "claimed release follows key identity after modifiers change and clears ownership" {
    var scratch: TextScratch = .{};
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    const bindings = defaultBindings(.linux_windows);

    const pressed = letterKey('c', .{ .ctrl = true, .shift = true }, .press);
    switch (resolve(&state, pressed, translate(&scratch, pressed, false), bindings)) {
        .action => {},
        else => return error.TestUnexpectedResult,
    }

    // Shift and Ctrl were released first. Ownership belongs to the key, so
    // its release is still Conduit's and removes the claim.
    const changed_release = letterKey('c', .{}, .release);
    switch (resolve(&state, changed_release, translate(&scratch, changed_release, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }

    // A second release has no claimed press and must not be swallowed merely
    // because its current modifiers happen to match the chord.
    const unowned_release = letterKey('c', .{ .ctrl = true, .shift = true }, .release);
    const translated = translate(&scratch, unowned_release, false);
    switch (resolve(&state, unowned_release, translated, bindings)) {
        .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }
}

test "an originally unbound key stays terminal after an extra modifier is released" {
    var scratch: TextScratch = .{};
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    const bindings = defaultBindings(.linux_windows);

    const unbound_press = letterKey('c', .{ .ctrl = true, .alt = true, .shift = true }, .press);
    const translated_press = translate(&scratch, unbound_press, false);
    switch (resolve(&state, unbound_press, translated_press, bindings)) {
        .terminal => |terminal_press| try expectTerminalPressExact(translated_press.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }

    // Alt is gone, so a stateless resolver would now mistake this for the
    // release of Ctrl+Shift+C even though the press went to the terminal.
    const release = letterKey('c', .{ .ctrl = true, .shift = true }, .release);
    const translated_release = translate(&scratch, release, false);
    switch (resolve(&state, release, translated_release, bindings)) {
        .terminal => |terminal_press| try expectTerminalPressExact(translated_release.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }
}

test "claimed repeats and duplicate presses do not invoke twice" {
    var scratch: TextScratch = .{};
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    const bindings = defaultBindings(.linux_windows);

    const press = letterKey('v', .{ .ctrl = true, .shift = true }, .press);
    switch (resolve(&state, press, translate(&scratch, press, false), bindings)) {
        .action => {},
        else => return error.TestUnexpectedResult,
    }

    const changed_repeat = letterKey('v', .{ .ctrl = true }, .repeat);
    switch (resolve(&state, changed_repeat, translate(&scratch, changed_repeat, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }

    const duplicate_press = letterKey('v', .{ .ctrl = true, .shift = true }, .press);
    switch (resolve(&state, duplicate_press, translate(&scratch, duplicate_press, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }

    const release = letterKey('v', .{}, .release);
    switch (resolve(&state, release, translate(&scratch, release, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }

    // The release cleared ownership, so the next real press invokes again.
    switch (resolve(&state, press, translate(&scratch, press, false), bindings)) {
        .action => {},
        else => return error.TestUnexpectedResult,
    }
}

test "binding state tracks two simultaneously held keys" {
    var scratch: TextScratch = .{};
    var binding_storage: [2]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    const bindings = defaultBindings(.linux_windows);
    const mods: platform.Mods = .{ .ctrl = true, .shift = true };

    const copy = letterKey('c', mods, .press);
    switch (resolve(&state, copy, translate(&scratch, copy, false), bindings)) {
        .action => {},
        else => return error.TestUnexpectedResult,
    }
    const paste = letterKey('v', mods, .press);
    switch (resolve(&state, paste, translate(&scratch, paste, false), bindings)) {
        .action => {},
        else => return error.TestUnexpectedResult,
    }

    const copy_repeat = letterKey('c', .{}, .repeat);
    switch (resolve(&state, copy_repeat, translate(&scratch, copy_repeat, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }
    const paste_release = letterKey('v', .{}, .release);
    switch (resolve(&state, paste_release, translate(&scratch, paste_release, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }

    const unowned_paste_repeat = letterKey('v', mods, .repeat);
    const translated = translate(&scratch, unowned_paste_repeat, false);
    switch (resolve(&state, unowned_paste_repeat, translated, bindings)) {
        .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }

    const copy_release = letterKey('c', .{}, .release);
    switch (resolve(&state, copy_release, translate(&scratch, copy_release, false), bindings)) {
        .consumed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "a full binding state leaves a matched transition entirely terminal-owned" {
    var scratch: TextScratch = .{};
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);
    const bindings = defaultBindings(.linux_windows);
    const mods: platform.Mods = .{ .ctrl = true, .shift = true };

    const copy = letterKey('c', mods, .press);
    switch (resolve(&state, copy, translate(&scratch, copy, false), bindings)) {
        .action => {},
        else => return error.TestUnexpectedResult,
    }

    const paste = letterKey('v', mods, .press);
    const translated_press = translate(&scratch, paste, false);
    switch (resolve(&state, paste, translated_press, bindings)) {
        .terminal => |terminal_press| try expectTerminalPressExact(translated_press.encoded, terminal_press),
        else => return error.TestUnexpectedResult,
    }

    for ([_]platform.KeyAction{ .repeat, .release }) |action| {
        const raw = letterKey('v', mods, action);
        const translated = translate(&scratch, raw, false);
        switch (resolve(&state, raw, translated, bindings)) {
            .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "named keys resolve through the same chord table" {
    const testing = std.testing;
    const arguments = [_]Argument{.{ .name = "direction", .value = "forward" }};
    const bindings = [_]Binding{.{
        .chord = .{ .key = .{ .named = .enter }, .modifiers = .{ .alt = true } },
        .action = "focus.advance",
        .arguments = &arguments,
    }};
    const raw: platform.KeyEvent = .{ .action = .press, .key = .enter, .mods = .{ .alt = true } };
    var scratch: TextScratch = .{};
    var binding_storage: [1]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);

    switch (resolve(&state, raw, translate(&scratch, raw, false), &bindings)) {
        .action => |request| {
            try testing.expectEqualStrings("focus.advance", request.action);
            try testing.expect(request.invocation.arguments.ptr == arguments[0..].ptr);
            try testing.expectEqualStrings("direction", request.invocation.arguments[0].name);
            try testing.expectEqualStrings("forward", request.invocation.arguments[0].value);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "unbound printable unicode named and modified keys preserve the terminal press" {
    const raws = [_]platform.KeyEvent{
        .{ .action = .press, .codepoint = 'q', .unshifted_codepoint = 'q' },
        .{ .action = .press, .codepoint = 0x03bb, .unshifted_codepoint = 0x03bb },
        .{ .action = .press, .key = .up },
        .{ .action = .press, .mods = .{ .ctrl = true }, .codepoint = 'x', .unshifted_codepoint = 'x' },
        .{ .action = .release, .key = .unidentified },
    };
    var binding_storage: [2]BindingKey = undefined;
    var state = BindingState.init(&binding_storage);

    for (raws) |raw| {
        var scratch: TextScratch = .{};
        const translated = translate(&scratch, raw, false);
        switch (resolve(&state, raw, translated, defaultBindings(.linux_windows))) {
            .terminal => |terminal_press| try expectTerminalPressExact(translated.encoded, terminal_press),
            else => return error.TestUnexpectedResult,
        }
    }
}

fn expectTerminalPressExact(expected: term.KeyPress, actual: term.KeyPress) !void {
    const testing = std.testing;
    try testing.expectEqual(expected.action, actual.action);
    try testing.expectEqual(expected.key, actual.key);
    try testing.expectEqual(expected.mods, actual.mods);
    try testing.expectEqual(expected.consumed_mods, actual.consumed_mods);
    try testing.expectEqual(expected.unshifted_codepoint, actual.unshifted_codepoint);
    try testing.expectEqual(expected.composing, actual.composing);
    try testing.expectEqual(expected.text.len, actual.text.len);
    try testing.expect(expected.text.ptr == actual.text.ptr);
    try testing.expectEqualStrings(expected.text, actual.text);
}

test "the lock keys are state, not intent" {
    const testing = std.testing;

    const caps_on: Modifiers = .{ .caps_lock = true, .shift = true };
    const normalized = caps_on.normalized();

    try testing.expect(normalized.shift);
    try testing.expect(!normalized.caps_lock);
    try testing.expect(!normalized.num_lock);
    try testing.expectEqual(normalized, caps_on.normalized().normalized());

    // A caps-locked letter with nothing else held is text, not a command.
    try testing.expect(!caps_on.isCommand());
    try testing.expect(!normalized.isCommand());
    try testing.expect(!(Modifiers{}).isCommand());
    try testing.expect((Modifiers{ .ctrl = true }).isCommand());
    try testing.expect((Modifiers{ .super = true }).isCommand());
    try testing.expect((Modifiers{ .alt = true }).isCommand());
}

test "only a bare character inserts text" {
    const testing = std.testing;

    const c = try Key.fromCharacter('c');

    const typed: KeyEvent = .{ .key = c, .modifiers = .{} };
    try testing.expectEqual(@as(u21, 'c'), typed.text().?);

    // Caps lock on, shift held: still the letter the keyboard reports.
    const locked: KeyEvent = .{ .key = c, .modifiers = .{ .caps_lock = true, .shift = true } };
    try testing.expectEqual(@as(u21, 'c'), locked.text().?);

    // Any modifier that changes what the key means makes it a command instead.
    try testing.expectEqual(null, (KeyEvent{ .key = c, .modifiers = .{ .ctrl = true } }).text());
    try testing.expectEqual(null, (KeyEvent{ .key = c, .modifiers = .{ .alt = true } }).text());
    try testing.expectEqual(null, (KeyEvent{ .key = c, .modifiers = .{ .super = true } }).text());

    // Named keys are never text.
    const enter: KeyEvent = .{ .key = .{ .named = .enter }, .modifiers = .{} };
    try testing.expectEqual(null, enter.text());
}

test "a control codepoint is not a key of its own" {
    const testing = std.testing;

    // Four samples were not enough: the excluded codepoints are three ranges
    // with printable holes between them, and a rule that is right for 0x03 and
    // wrong for 0x80 is not a rule. Every codepoint in every range is refused.
    for (0..0x20) |codepoint| {
        try testing.expectError(error.ControlCharacter, Key.fromCharacter(@intCast(codepoint)));
    }
    try testing.expectError(error.ControlCharacter, Key.fromCharacter(0x7f));
    for (0x80..0xa0) |codepoint| {
        try testing.expectError(error.ControlCharacter, Key.fromCharacter(@intCast(codepoint)));
    }

    try testing.expectEqual(Key{ .character = 'a' }, try Key.fromCharacter('a'));

    // The boundaries either side of each excluded range, and the ends of the
    // Unicode range: the first codepoint after a range is a character key, and
    // so is the last one before the next.
    for ([_]u21{ 0x20, 0x21, 0x7e, 0xa0, 0xa1, 0x10ffff }) |codepoint| {
        try testing.expectEqual(Key{ .character = codepoint }, try Key.fromCharacter(codepoint));
    }
}

test "the same rule holds where a press becomes text" {
    const testing = std.testing;
    var scratch: TextScratch = .{};

    // `translate` asks the control question twice — once for the text a press
    // produces and once for whether it is a bindable character — and both
    // answers have to be the answer above. So the whole excluded range is
    // refused here too: no text, and no intent to match a binding against.
    for (0..0x20) |codepoint| {
        const press = translate(&scratch, osKey(.unidentified, @intCast(codepoint), 0, .{}), false);
        try testing.expectEqual(@as(?KeyEvent, null), press.intent);
        try testing.expectEqualStrings("", press.encoded.text);
    }
    try testing.expectEqual(@as(?KeyEvent, null), translate(&scratch, osKey(.unidentified, 0x7f, 0, .{}), false).intent);
    for (0x80..0xa0) |codepoint| {
        const press = translate(&scratch, osKey(.unidentified, @intCast(codepoint), 0, .{}), false);
        try testing.expectEqual(@as(?KeyEvent, null), press.intent);
        try testing.expectEqualStrings("", press.encoded.text);
    }

    // The boundaries are ordinary text, one and three bytes of UTF-8.
    const space = translate(&scratch, osKey(.unidentified, 0x20, 0x20, .{}), false);
    try testing.expectEqual(@as(u21, 0x20), space.intent.?.text().?);
    try testing.expectEqualStrings(" ", space.encoded.text);
    const nbsp = translate(&scratch, osKey(.unidentified, 0xa0, 0xa0, .{}), false);
    try testing.expectEqual(@as(u21, 0xa0), nbsp.intent.?.text().?);
    try testing.expectEqualStrings("\xc2\xa0", nbsp.encoded.text);

    // The last codepoint in the Unicode range is still a character key, and
    // still fits in four bytes.
    const top = translate(&scratch, osKey(.unidentified, 0x10ffff, 0x10ffff, .{}), false);
    try testing.expectEqual(@as(u21, 0x10ffff), top.intent.?.text().?);
    try testing.expectEqualStrings("\xf4\x8f\xbf\xbf", top.encoded.text);
}

// ---------------------------------------------------------------------------
// Tests: the translation table
// ---------------------------------------------------------------------------

/// A key event as the OS would report it, without an SDL event in hand: the
/// tests below are about Conduit's table, not about SDL's.
fn osKey(key: platform.Key, codepoint: u21, unshifted: u21, mods: platform.Mods) platform.KeyEvent {
    return .{ .action = .press, .key = key, .mods = mods, .codepoint = codepoint, .unshifted_codepoint = unshifted };
}

/// The encoding of one key press, into the caller's own `out`.
///
/// `out` is a parameter rather than a local for the same reason the press borrows
/// `scratch`: a slice into a value that dies when this function returns is a slice of
/// whatever the next call left behind. Every caller owns an `EncodedKey`, exactly as the
/// production callers of `Terminal.encodeKey` do.
fn encode(
    terminal: *const term.Terminal,
    scratch: *TextScratch,
    raw: platform.KeyEvent,
    out: *term.EncodedKey,
) []const u8 {
    terminal.encodeKey(translate(scratch, raw, false).encoded, out);
    return out.slice();
}

test "every named key becomes the terminal key of the same name" {
    const testing = std.testing;

    // The table is written out rather than derived, because the encoder and the
    // registry must never disagree about which key a press was: one switch,
    // one answer, and a key added to one enum without the other is a compile
    // error here.
    try testing.expectEqual(named_keys.len, @typeInfo(Named).@"enum".fields.len);
    try testing.expectEqual(named_keys.len, @typeInfo(platform.Key).@"enum".fields.len - 1);

    // Each named key maps to itself in both vocabularies, and no two keys share
    // a name — a duplicate would make one of them silently unreachable.
    var seen = std.EnumSet(Named).initEmpty();
    inline for (named_keys) |named| {
        const entry = intentOf(@field(platform.Key, @tagName(named))) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(named, entry.named);
        try testing.expectEqual(@field(term.PhysicalKey, @tagName(named)), entry.encoded);
        // No two keys may share a name: a duplicate would make one of them
        // silently unreachable through `intentOf`.
        try testing.expect(!seen.contains(named));
        seen.insert(named);
    }
    try testing.expectEqual(@as(?IntentKey, null), intentOf(.unidentified));
}

test "a named key is intent with no character, and encodes with no text" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var scratch: TextScratch = .{};
    var encoded: term.EncodedKey = .{};
    const cases = [_]struct { key: platform.Key, named: Named, bytes: []const u8 }{
        .{ .key = .enter, .named = .enter, .bytes = "\r" },
        .{ .key = .tab, .named = .tab, .bytes = "\t" },
        .{ .key = .backspace, .named = .backspace, .bytes = "\x7f" },
        .{ .key = .escape, .named = .escape, .bytes = "\x1b" },
        .{ .key = .insert, .named = .insert, .bytes = "\x1b[2~" },
        .{ .key = .delete, .named = .delete, .bytes = "\x1b[3~" },
        .{ .key = .up, .named = .up, .bytes = "\x1b[A" },
        .{ .key = .down, .named = .down, .bytes = "\x1b[B" },
        .{ .key = .right, .named = .right, .bytes = "\x1b[C" },
        .{ .key = .left, .named = .left, .bytes = "\x1b[D" },
        .{ .key = .home, .named = .home, .bytes = "\x1b[H" },
        .{ .key = .end, .named = .end, .bytes = "\x1b[F" },
        .{ .key = .page_up, .named = .page_up, .bytes = "\x1b[5~" },
        .{ .key = .page_down, .named = .page_down, .bytes = "\x1b[6~" },
        .{ .key = .f1, .named = .f1, .bytes = "\x1bOP" },
        .{ .key = .f2, .named = .f2, .bytes = "\x1bOQ" },
        .{ .key = .f3, .named = .f3, .bytes = "\x1bOR" },
        .{ .key = .f4, .named = .f4, .bytes = "\x1bOS" },
        .{ .key = .f5, .named = .f5, .bytes = "\x1b[15~" },
        .{ .key = .f6, .named = .f6, .bytes = "\x1b[17~" },
        .{ .key = .f7, .named = .f7, .bytes = "\x1b[18~" },
        .{ .key = .f8, .named = .f8, .bytes = "\x1b[19~" },
        .{ .key = .f9, .named = .f9, .bytes = "\x1b[20~" },
        .{ .key = .f10, .named = .f10, .bytes = "\x1b[21~" },
        .{ .key = .f11, .named = .f11, .bytes = "\x1b[23~" },
        .{ .key = .f12, .named = .f12, .bytes = "\x1b[24~" },
    };
    try testing.expectEqual(cases.len, named_keys.len);

    for (cases) |case| {
        const press = translate(&scratch, osKey(case.key, 0, 0, .{}), false);
        try testing.expectEqual(Key{ .named = case.named }, press.intent.?.key);
        // A named key has no text of its own: enter is a key, not the two
        // characters \ and r.
        try testing.expectEqualStrings("", press.encoded.text);
        try testing.expectEqualStrings(
            case.bytes,
            encode(&terminal, &scratch, osKey(case.key, 0, 0, .{}), &encoded),
        );
    }
}

test "a character key carries its character, and a control one carries none" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var scratch: TextScratch = .{};
    var encoded: term.EncodedKey = .{};

    // Plain text: the character, as intent and as text.
    const plain = translate(&scratch, osKey(.unidentified, 'a', 'a', .{}), false);
    try testing.expectEqual(Key{ .character = 'a' }, plain.intent.?.key);
    try testing.expectEqual(@as(u21, 'a'), plain.intent.?.text().?);
    try testing.expectEqualStrings("a", plain.encoded.text);
    try testing.expectEqual(term.PhysicalKey.unidentified, plain.encoded.key);

    // A multi-byte character survives the round trip through four bytes.
    const wide = translate(&scratch, osKey(.unidentified, 0x3042, 0x3042, .{}), false);
    try testing.expectEqual(@as(u21, 0x3042), wide.intent.?.key.character);
    try testing.expectEqualStrings("\xe3\x81\x82", wide.encoded.text);
    try testing.expectEqualStrings("\xe3\x81\x82", encode(&terminal, &scratch, osKey(.unidentified, 0x3042, 0x3042, .{}), &encoded));

    // A character that is a control character is not text and not intent: it
    // is what the encoder makes of ctrl and the letter, and some platforms
    // report it as the keycode of the key itself.
    for ([_]u21{ 0x00, 0x03, 0x09, 0x1b, 0x7f, 0x80, 0x9b }) |control| {
        const press = translate(&scratch, osKey(.unidentified, control, 'a', .{ .ctrl = true }), false);
        try testing.expectEqual(@as(?KeyEvent, null), press.intent);
        try testing.expectEqualStrings("", press.encoded.text);
    }

    // The boundaries either side of the excluded range are ordinary
    // characters.
    try testing.expectEqualStrings(" ", translate(&scratch, osKey(.unidentified, 0x20, 0x20, .{}), false).encoded.text);
    try testing.expectEqualStrings("\xc2\xa0", translate(&scratch, osKey(.unidentified, 0xa0, 0xa0, .{}), false).encoded.text);
}

test "the modifier matrix decides what a key means and what it sends" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);
    // These expectations are Alt's: ESC-prefixed. On macOS the key is Option,
    // which composes characters unless Option-as-Alt is configured (and the
    // product policy for that is TASK-15), so ask for Alt explicitly there.
    // Off macOS the setting is inert.
    terminal.setMacosOptionAsAlt(true);

    var scratch: TextScratch = .{};
    var encoded: term.EncodedKey = .{};

    // Every combination of the four command modifiers on one letter, with the
    // bytes a program receives for it. Written out in full because the four
    // do not commute: ctrl and alt together are a C0 byte behind an escape,
    // ctrl and shift together are a CSI u sequence, and super on its own is
    // nothing at all — a terminal does not report the window manager's key.
    //
    // The rule the bytes below follow: ctrl alone with the letter is its C0
    // byte, alt prefixes whatever the rest of the press encodes with an
    // escape, ctrl with shift is fixterms' CSI u with the modifiers that are
    // left, and a press with no command modifier is the character the layout
    // produced.
    const cases = [_]struct { mods: platform.Mods, bytes: []const u8, text: bool }{
        .{ .mods = .{}, .bytes = "a", .text = true },
        .{ .mods = .{ .shift = true }, .bytes = "A", .text = true },
        .{ .mods = .{ .alt = true }, .bytes = "\x1ba", .text = false },
        .{ .mods = .{ .alt = true, .shift = true }, .bytes = "\x1bA", .text = false },
        // Super with only the character is the character on Linux and Windows,
        // and nothing at all on macOS, where Command+key never types text in
        // Terminal.app or iTerm2 and the engine follows them.
        .{ .mods = .{ .super = true }, .bytes = if (builtin.os.tag == .macos) "" else "a", .text = false },
        .{ .mods = .{ .super = true, .shift = true }, .bytes = if (builtin.os.tag == .macos) "" else "A", .text = false },
        .{ .mods = .{ .alt = true, .super = true }, .bytes = "\x1ba", .text = false },
        .{ .mods = .{ .alt = true, .shift = true, .super = true }, .bytes = "\x1bA", .text = false },
        .{ .mods = .{ .ctrl = true }, .bytes = "\x01", .text = false },
        .{ .mods = .{ .ctrl = true, .alt = true }, .bytes = "\x1b\x01", .text = false },
        // CSI u's modifier number is 1 + shift(1) + alt(2) + ctrl(4), and it
        // has no super bit at all: fixterms' CSI u reports three modifiers,
        // and super is reported by the Kitty protocol instead. So ctrl+super
        // encodes as the same 5 as ctrl does, and adding super to the other
        // three changes nothing: 6 is shift and ctrl, 7 adds alt, 8 is all
        // three.
        .{ .mods = .{ .ctrl = true, .shift = true }, .bytes = "\x1b[97;6u", .text = false },
        .{ .mods = .{ .ctrl = true, .alt = true, .shift = true }, .bytes = "\x1b[97;8u", .text = false },
        .{ .mods = .{ .ctrl = true, .super = true }, .bytes = "\x1b[97;5u", .text = false },
        .{ .mods = .{ .ctrl = true, .shift = true, .super = true }, .bytes = "\x1b[97;6u", .text = false },
        .{ .mods = .{ .ctrl = true, .alt = true, .super = true }, .bytes = "\x1b[97;7u", .text = false },
        .{ .mods = .{ .ctrl = true, .alt = true, .shift = true, .super = true }, .bytes = "\x1b[97;8u", .text = false },
        // The lock keys are state rather than intent: a caps-locked letter is
        // still text rather than a command, and a program reading ctrl+caps+a
        // gets the same byte it gets from ctrl+a — the layout has already
        // applied the lock to the character, and the unshifted codepoint is
        // what tells the two apart.
        .{ .mods = .{ .ctrl = true, .caps_lock = true }, .bytes = "\x01", .text = false },
        .{ .mods = .{ .ctrl = true, .num_lock = true }, .bytes = "\x01", .text = false },
        .{ .mods = .{ .ctrl = true, .caps_lock = true, .num_lock = true }, .bytes = "\x01", .text = false },
        .{ .mods = .{ .caps_lock = true }, .bytes = "A", .text = true },
        .{ .mods = .{ .caps_lock = true, .alt = true }, .bytes = "\x1bA", .text = false },
    };

    for (cases) |case| {
        // The codepoint is the character the layout produced with shift and
        // caps lock applied, and the unshifted one is the same key without
        // either: that pair is what lets a terminal tell ctrl+a from ctrl+A.
        const codepoint: u21 = if (case.mods.shift or case.mods.caps_lock) 'A' else 'a';
        const raw = osKey(.unidentified, codepoint, 'a', case.mods);
        const press = translate(&scratch, raw, false);

        try testing.expectEqual(case.text, press.intent.?.text() != null);
        try testing.expectEqualStrings(case.bytes, encode(&terminal, &scratch, raw, &encoded));

        // Shift is consumed only when it produced the character.
        try testing.expectEqual(case.mods.shift, press.encoded.consumed_mods.shift);
        try testing.expectEqual(@as(u21, 'a'), press.encoded.unshifted_codepoint);
    }

    // Every modifier reaches both layers intact.
    const all: platform.Mods = .{ .ctrl = true, .alt = true, .shift = true, .super = true, .caps_lock = true, .num_lock = true };
    const press = translate(&scratch, osKey(.f5, 0, 0, all), false);
    try testing.expectEqual(Modifiers{
        .ctrl = true,
        .alt = true,
        .shift = true,
        .super = true,
        .caps_lock = true,
        .num_lock = true,
    }, press.intent.?.modifiers);
    try testing.expectEqual(term.KeyMods{
        .ctrl = true,
        .alt = true,
        .shift = true,
        .super = true,
        .caps_lock = true,
        .num_lock = true,
    }, press.encoded.mods);
}

test "a press, a release and a repeat are three different things" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var scratch: TextScratch = .{};

    const press = translate(&scratch, .{ .action = .press, .key = .unidentified, .codepoint = 'a', .unshifted_codepoint = 'a' }, false);
    try testing.expectEqual(term.KeyAction.press, press.encoded.action);

    const repeated = translate(&scratch, .{ .action = .repeat, .key = .unidentified, .codepoint = 'a', .unshifted_codepoint = 'a' }, false);
    try testing.expectEqual(term.KeyAction.repeat, repeated.encoded.action);

    const released = translate(&scratch, .{ .action = .release, .key = .unidentified, .codepoint = 'a', .unshifted_codepoint = 'a' }, false);
    try testing.expectEqual(term.KeyAction.release, released.encoded.action);

    // Legacy has no release, so a release sends nothing rather than sending the
    // character again.
    var encoded: term.EncodedKey = .{};
    terminal.encodeKey(released.encoded, &encoded);
    try testing.expect(encoded.isEmpty());
    terminal.encodeKey(repeated.encoded, &encoded);
    try testing.expectEqualStrings("a", encoded.slice());
}

// ---------------------------------------------------------------------------
// Tests: input methods
// ---------------------------------------------------------------------------

test "a preedit is held for the renderer and never sent to the child" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 20, .rows = 2 });
    defer terminal.deinit(testing.allocator);

    var composition: Composition = .{};
    var scratch: TextScratch = .{};

    // Nothing composed yet: every key is a keystroke.
    try testing.expect(!composition.isComposing());
    const typed = translate(&scratch, osKey(.unidentified, 'a', 'a', .{}), composition.isComposing());
    try testing.expect(!typed.encoded.composing);

    // An input method starts composing "konnichiha" — ten bytes — with the
    // last four of them selected, which is what an input method selecting a
    // segment reports: a start of 6 and a length of 4. The pair has to be
    // self-consistent, because `TextEditing.editing` clamps a length to the
    // text left after the start, and (9, 4) describes a selection the text
    // does not contain.
    composition.update(platform.TextEditing.editing("konnichiha", 6, 4));
    try testing.expect(composition.isComposing());
    try testing.expectEqualStrings("konnichiha", composition.preedit());
    try testing.expectEqual(@as(u32, 6), composition.selection().start);
    try testing.expectEqual(@as(u32, 4), composition.selection().length);

    // Every key pressed while it composes is display-only. This is the property
    // the whole design rests on, and it holds because the encoder emits nothing
    // for a composing press — there is no check here to forget.
    var encoded: term.EncodedKey = .{};
    const during = translate(&scratch, osKey(.unidentified, 'a', 'a', .{}), composition.isComposing());
    try testing.expect(during.encoded.composing);
    terminal.encodeKey(during.encoded, &encoded);
    try testing.expect(encoded.isEmpty());

    // Even the key that commits it: the input method, not the key, produces
    // the text.
    const commit_key = translate(&scratch, osKey(.enter, 0, 0, .{}), composition.isComposing());
    terminal.encodeKey(commit_key.encoded, &encoded);
    try testing.expect(encoded.isEmpty());

    // The commit: the preedit goes away and the finished text is the child's,
    // as the exact bytes the session writes to the PTY. Committed text is not
    // a key press — it has no key and no modifiers — so it does not go through
    // the encoder at all, which is also why it cannot be swallowed by a
    // protocol that reports nothing for an unidentified key.
    var child_input: [64]u8 = undefined;
    const committed = composition.commit("こんにちは");
    @memcpy(child_input[0..committed.len], committed);
    try testing.expect(!composition.isComposing());
    try testing.expectEqualStrings("", composition.preedit());
    try testing.expectEqualStrings("こんにちは", child_input[0..committed.len]);
}

test "the composition's selection follows the input method, and its offsets are safe" {
    const testing = std.testing;

    var composition: Composition = .{};

    composition.update(platform.TextEditing.editing("にほん", 0, 0));
    try testing.expectEqualStrings("にほん", composition.preedit());
    try testing.expect(composition.selection().isCursorOnly());

    composition.update(platform.TextEditing.editing("にほんご", 9, 3));
    try testing.expectEqualStrings("にほんご", composition.preedit());
    try testing.expectEqual(@as(u32, 9), composition.selection().start);
    try testing.expectEqual(@as(u32, 3), composition.selection().length);

    // An input method that reports a selection past the end of its own text
    // is making a number up, and the number is clamped rather than believed:
    // the alternative is a selection reaching past the preedit.
    composition.update(platform.TextEditing.editing("に", 900, 900));
    try testing.expectEqualStrings("に", composition.preedit());
    try testing.expect(composition.selection().start <= composition.preedit().len);
    try testing.expectEqual(
        composition.preedit().len - composition.selection().start,
        composition.selection().length,
    );

    // A preedit longer than the buffer is truncated, and says so, rather than
    // being allowed to make Conduit allocate on the render thread.
    var huge: [Composition.max_preedit + 32]u8 = undefined;
    @memset(&huge, 'x');
    composition.update(platform.TextEditing.editing(&huge, 0, 0));
    try testing.expectEqual(Composition.max_preedit, composition.preedit().len);
    try testing.expect(composition.truncated);

    // A composition that is cancelled leaves nothing behind, which is what a
    // user pressing Escape expects to see happen.
    composition.update(platform.TextEditing.editing("nope", 0, 0));
    composition.cancel();
    try testing.expect(!composition.isComposing());
    try testing.expectEqualStrings("", composition.preedit());
}

test "candidates are held with the composition and dropped when it ends" {
    const testing = std.testing;

    var composition: Composition = .{};
    composition.update(platform.TextEditing.editing("konn", 0, 0));
    composition.setCandidates(platform.Candidates.candidates(&.{ "こんにちは", "こんにちわ" }, 1, false));

    try testing.expectEqual(@as(usize, 2), composition.offered().len());
    try testing.expectEqualStrings("こんにちわ", composition.offered().current().?);

    // Committing takes the candidates with it: they were alternatives to text
    // that no longer exists.
    _ = composition.commit("こんにちは");
    try testing.expectEqual(@as(usize, 0), composition.offered().len());
    try testing.expectEqual(@as(?[]const u8, null), composition.offered().current());
}

test "a shift press reaches the terminal as the user's, and a bare one as the program's" {
    const testing = std.testing;

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 40, .rows = 6 });
    defer terminal.deinit(testing.allocator);
    terminal.feed("alpha bravo charlie\r\ndelta echo foxtrot\r\n");
    try terminal.refresh(testing.allocator);

    // The geometry is the one the app builds from the surface and the face:
    // 10x20 pixel cells in a 400x120 surface, so a column is a pixel position
    // no rounding can be argued about.
    const geometry: PointerGeometry = .{
        .surface_width_px = 400,
        .surface_height_px = 120,
        .cell_width_px = 10,
        .cell_height_px = 20,
    };

    // A program takes the mouse the way `vim` does, and the events below are
    // in the shape the platform hands over. This is the middle of the chain —
    // platform event, `input`, terminal — and it is where a translation that
    // dropped the modifiers would be invisible everywhere else: the report
    // would still be a report, it would just go to the wrong owner.
    terminal.feed("\x1b[?1006;1000h\x1b[?1002h");

    // Unshifted: the program's. The report names the cell the pointer is over,
    // one-based as the protocol counts, which is what says the geometry
    // survived the translation rather than being defaulted somewhere.
    const press = pointerButton(&geometry, .{
        .button = .left,
        .action = .press,
        .x = 25,
        .y = 10,
    });
    try testing.expectEqual(term.PointerOwner.program, terminal.pointerOwner(press.mods));
    try testing.expectEqual(@as(u16, 2), terminal.cellAt(press.pointer).col);

    var encoded: term.EncodedKey = .{};
    _ = terminal.pointerEvent(press, null, &encoded);
    try testing.expectEqualStrings("\x1b[<0;3;1M", encoded.slice());

    // Shifted: the user's, in both halves of the gesture. The drag is a real
    // selection over real text, and the program is told nothing at all — an
    // empty `encoded` is the claim, because those are the bytes it would have
    // been written.
    const shift: platform.Mods = .{ .shift = true };
    const shifted = pointerButton(&geometry, .{
        .button = .left,
        .action = .press,
        .mods = shift,
        .x = 25,
        .y = 10,
    });
    try testing.expectEqual(term.PointerOwner.user, terminal.pointerOwner(shifted.mods));
    _ = terminal.pointerEvent(shifted, null, &encoded);
    const drag = pointerMotion(&geometry, .{
        .buttons = .{ .left = true },
        .mods = shift,
        .x = 75,
        .y = 10,
    });
    _ = terminal.pointerEvent(drag, null, &encoded);
    try testing.expectEqual(@as(usize, 0), encoded.len);
    try testing.expect(terminal.hasSelection());
    const text = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("pha b", text);

    // Alt reaches the terminal too, and it is the one that makes a drag a
    // block selection. A translation that dropped it would leave the
    // capability unreachable and nothing else would notice.
    //
    // The program gives the mouse back first, because while it holds the
    // pointer *no* unshifted drag is the user's — Alt included — and an Alt
    // drag there would be a report carrying the Alt bit, which is the other
    // half of the same rule the Shift case above proved.
    const alt: platform.Mods = .{ .alt = true };
    terminal.feed("\x1b[?1002l\x1b[?1000l\x1b[?9l");
    const alt_press = pointerButton(&geometry, .{
        .button = .left,
        .action = .press,
        .mods = alt,
        .x = 25,
        .y = 30,
    });
    try testing.expect(alt_press.mods.alt);
    _ = terminal.pointerEvent(alt_press, null, &encoded);
    const alt_drag = pointerMotion(&geometry, .{
        .buttons = .{ .left = true },
        .mods = alt,
        .x = 65,
        .y = 50,
    });
    _ = terminal.pointerEvent(alt_drag, null, &encoded);
    try testing.expectEqual(@as(usize, 0), encoded.len);
    const rectangle = (try terminal.selectionText(testing.allocator)).?;
    defer testing.allocator.free(rectangle);
    try testing.expectEqualStrings("lta ", rectangle);
}

// ---------------------------------------------------------------------------
// Tests: clipboard intents
// ---------------------------------------------------------------------------

/// A key press of `letter` with `mods`, shaped the way SDL reports it: the
/// character with shift applied, and the unshifted one beside it.
fn letterKey(letter: u21, mods: platform.Mods, action: platform.KeyAction) platform.KeyEvent {
    const shifted = if (mods.shift and letter >= 'a' and letter <= 'z') letter - 0x20 else letter;
    return .{ .action = action, .key = .unidentified, .mods = mods, .codepoint = shifted, .unshifted_codepoint = letter };
}

test "ctrl+c with nothing selected is never a copy, whatever else is true" {
    const testing = std.testing;

    // The whole space a Ctrl+C can arrive in with nothing selected: both chord
    // sets, the copy setting both ways, every action, and the lock keys in all
    // four states. The rule is "always", so the test is every case rather than
    // a sample of them.
    const actions = [_]platform.KeyAction{ .press, .repeat, .release };
    for (std.enums.values(ClipboardChords)) |chords| {
        for ([_]bool{ false, true }) |configured| {
            for (actions) |action| {
                for ([_]bool{ false, true }) |caps| {
                    for ([_]bool{ false, true }) |num| {
                        const press = letterKey('c', .{ .ctrl = true, .caps_lock = caps, .num_lock = num }, action);
                        try testing.expectEqual(ClipboardKey.terminal, clipboardKey(press, .{
                            .has_selection = false,
                            .chords = chords,
                            .ctrl_c_copies_selection = configured,
                        }));
                    }
                }
            }
        }
    }

    // And the key that reaches the terminal is the interrupt: the same press,
    // translated and encoded, is the single byte 0x03.
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var terminal: term.Terminal = undefined;
    try terminal.init(threaded.io(), testing.allocator, .{ .cols = 20, .rows = 4 });
    defer terminal.deinit(testing.allocator);
    var scratch: TextScratch = .{};
    var out: term.EncodedKey = .{};
    try testing.expectEqualStrings("\x03", encode(&terminal, &scratch, letterKey('c', .{ .ctrl = true }, .press), &out));
}

test "the copy chord copies a selection, and is swallowed without one" {
    const testing = std.testing;
    const selected: ClipboardKeyContext = .{ .has_selection = true, .chords = .ctrl_shift };
    const empty: ClipboardKeyContext = .{ .has_selection = false, .chords = .ctrl_shift };
    const chord: platform.Mods = .{ .ctrl = true, .shift = true };

    try testing.expectEqual(ClipboardKey.copy, clipboardKey(letterKey('c', chord, .press), selected));
    // The shifted character is what most layouts report; the unshifted one is
    // what decides, so an OS that reports either is recognised.
    var lower = letterKey('c', chord, .press);
    lower.codepoint = 'c';
    try testing.expectEqual(ClipboardKey.copy, clipboardKey(lower, selected));
    var no_unshifted = letterKey('c', chord, .press);
    no_unshifted.unshifted_codepoint = 0;
    try testing.expectEqual(ClipboardKey.copy, clipboardKey(no_unshifted, selected));
    // Caps lock is state, not intent.
    try testing.expectEqual(ClipboardKey.copy, clipboardKey(letterKey('c', .{ .ctrl = true, .shift = true, .caps_lock = true }, .press), selected));
    // The chord's release and repeat neither copy again nor reach the program.
    try testing.expectEqual(ClipboardKey.swallow, clipboardKey(letterKey('c', chord, .release), selected));
    try testing.expectEqual(ClipboardKey.swallow, clipboardKey(letterKey('c', chord, .repeat), selected));
    // With nothing selected the chord does nothing at all: it is Conduit's
    // chord, so it is not sent on to the program as Ctrl+Shift+C either.
    try testing.expectEqual(ClipboardKey.swallow, clipboardKey(letterKey('c', chord, .press), empty));
}

test "a plain ctrl+c copies only with a selection, and only when configured to" {
    const testing = std.testing;
    const ctrl: platform.Mods = .{ .ctrl = true };

    try testing.expectEqual(ClipboardKey.copy_and_deselect, clipboardKey(letterKey('c', ctrl, .press), .{
        .has_selection = true,
        .chords = .ctrl_shift,
    }));
    try testing.expectEqual(ClipboardKey.swallow, clipboardKey(letterKey('c', ctrl, .release), .{
        .has_selection = true,
        .chords = .ctrl_shift,
    }));
    // Turned off, a selection does not stop Ctrl+C being SIGINT.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('c', ctrl, .press), .{
        .has_selection = true,
        .chords = .ctrl_shift,
        .ctrl_c_copies_selection = false,
    }));
    // On macOS Cmd+C is the copy, so Ctrl+C stays the program's even with a
    // selection.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('c', ctrl, .press), .{
        .has_selection = true,
        .chords = .command,
    }));
    // Any other modifier with Ctrl makes it a different key, and the program's.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('c', .{ .ctrl = true, .alt = true }, .press), .{
        .has_selection = true,
        .chords = .ctrl_shift,
    }));
}

test "the paste chord pastes on press, and the other platform's chords are the program's" {
    const testing = std.testing;
    const linux: ClipboardKeyContext = .{ .has_selection = false, .chords = .ctrl_shift };
    const macos: ClipboardKeyContext = .{ .has_selection = true, .chords = .command };

    try testing.expectEqual(ClipboardKey.paste, clipboardKey(letterKey('v', .{ .ctrl = true, .shift = true }, .press), linux));
    try testing.expectEqual(ClipboardKey.swallow, clipboardKey(letterKey('v', .{ .ctrl = true, .shift = true }, .release), linux));
    // Plain Ctrl+V is literal-next in a shell, and stays the shell's.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('v', .{ .ctrl = true }, .press), linux));
    // Cmd+C/V are not chords on Linux and Windows.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('v', .{ .super = true }, .press), linux));
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('c', .{ .super = true }, .press), .{ .has_selection = true, .chords = .ctrl_shift }));

    try testing.expectEqual(ClipboardKey.copy, clipboardKey(letterKey('c', .{ .super = true }, .press), macos));
    try testing.expectEqual(ClipboardKey.paste, clipboardKey(letterKey('v', .{ .super = true }, .press), macos));
    try testing.expectEqual(ClipboardKey.swallow, clipboardKey(letterKey('c', .{ .super = true }, .press), .{ .has_selection = false, .chords = .command }));
    // Ctrl+Shift+C/V are not chords on macOS.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('c', .{ .ctrl = true, .shift = true }, .press), macos));
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('v', .{ .ctrl = true, .shift = true }, .press), macos));

    // Other letters, unmodified letters and named keys are never chords.
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('x', .{ .ctrl = true, .shift = true }, .press), linux));
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(letterKey('c', .{}, .press), macos));
    try testing.expectEqual(ClipboardKey.terminal, clipboardKey(.{
        .action = .press,
        .key = .insert,
        .mods = .{ .ctrl = true, .shift = true },
    }, linux));

    // The build's own set is the one its platform uses.
    try testing.expectEqual(
        if (builtin.os.tag == .macos) ClipboardChords.command else ClipboardChords.ctrl_shift,
        ClipboardChords.native,
    );
}

test "a middle press pastes the primary selection only where one exists and the user owns the pointer" {
    const testing = std.testing;
    const middle: platform.PointerButton = .{ .button = .middle, .action = .press, .x = 5, .y = 5 };

    try testing.expect(primaryPaste(middle, .user, true));
    try testing.expect(!primaryPaste(middle, .user, false));
    try testing.expect(!primaryPaste(middle, .program, true));
    var release = middle;
    release.action = .release;
    try testing.expect(!primaryPaste(release, .user, true));
    var left = middle;
    left.button = .left;
    try testing.expect(!primaryPaste(left, .user, true));
    var right = middle;
    right.button = .right;
    try testing.expect(!primaryPaste(right, .user, true));

    // The build's answer is Linux's.
    try testing.expectEqual(builtin.os.tag == .linux, platform.primary_selection_supported);
}

const echo_testing = std.testing;

fn echoAfterPress(echo: *KeyTextEcho, raw: platform.KeyEvent) !void {
    var scratch: TextScratch = .{};
    const event: platform.Event = .{ .key = raw };
    try echo_testing.expect(!echo.filter(event));
    echo.recordTerminalPress(raw, translate(&scratch, raw, false));
}

test "a key's identical text echo is dropped exactly once" {
    var echo: KeyTextEcho = .{};
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'h' });
    try echo_testing.expect(echo.filter(.{ .text_input = "h" }));
    // The record is consumed: a second identical text is real text.
    try echo_testing.expect(!echo.filter(.{ .text_input = "h" }));

    try echoAfterPress(&echo, .{ .action = .repeat, .codepoint = 'h' });
    try echo_testing.expect(echo.filter(.{ .text_input = "h" }));
}

test "text that differs from the key's character is committed" {
    var echo: KeyTextEcho = .{};
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'g' });
    try echo_testing.expect(!echo.filter(.{ .text_input = "한" }));
    // The mismatch also consumed the record.
    try echo_testing.expect(!echo.filter(.{ .text_input = "g" }));
}

test "text with no preceding key is committed" {
    var echo: KeyTextEcho = .{};
    try echo_testing.expect(!echo.filter(.{ .text_input = "hello" }));
    try echo_testing.expect(!echo.filter(.{ .text_input = "" }));
}

test "any key event or preedit clears the pending key text" {
    var echo: KeyTextEcho = .{};
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'a' });
    try echo_testing.expect(!echo.filter(.{ .key = .{ .action = .release, .codepoint = 'a' } }));
    try echo_testing.expect(!echo.filter(.{ .text_input = "a" }));

    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'a' });
    try echoAfterPress(&echo, .{ .action = .press, .key = .enter });
    try echo_testing.expect(!echo.filter(.{ .text_input = "a" }));

    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'k' });
    try echo_testing.expect(!echo.filter(.{ .text_editing = platform.TextEditing.editing("k", 1, 0) }));
    try echo_testing.expect(!echo.filter(.{ .text_input = "k" }));

    // Recording a release leaves nothing behind either.
    try echoAfterPress(&echo, .{ .action = .release, .codepoint = 'a' });
    try echo_testing.expect(!echo.filter(.{ .text_input = "a" }));
}

test "alt records the bare character and ctrl or super records nothing" {
    var echo: KeyTextEcho = .{};
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'x', .mods = .{ .alt = true } });
    try echo_testing.expect(echo.filter(.{ .text_input = "x" }));

    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'c', .mods = .{ .ctrl = true } });
    try echo_testing.expect(!echo.filter(.{ .text_input = "c" }));

    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'v', .mods = .{ .super = true } });
    try echo_testing.expect(!echo.filter(.{ .text_input = "v" }));

    // A control codepoint is not text on the key path.
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 0x03 });
    try echo_testing.expect(!echo.filter(.{ .text_input = "\x03" }));
}

test "a shifted or four-byte character is matched by its full UTF-8" {
    var echo: KeyTextEcho = .{};
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 'H', .unshifted_codepoint = 'h', .mods = .{ .shift = true } });
    try echo_testing.expect(echo.filter(.{ .text_input = "H" }));

    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 0x1F600 });
    try echo_testing.expect(!echo.filter(.{ .text_input = "\xF0\x9F\x98" }));
    try echoAfterPress(&echo, .{ .action = .press, .codepoint = 0x1F600 });
    try echo_testing.expect(echo.filter(.{ .text_input = "\u{1F600}" }));
}

test "an Input's typed key text is dropped from its echo once" {
    var echo: KeyTextEcho = .{};
    const press: platform.KeyEvent = .{ .action = .press, .codepoint = 'Y', .unshifted_codepoint = 'y', .mods = .{ .shift = true } };
    try echo_testing.expect(!echo.filter(.{ .key = press }));
    echo.recordKeyText(press, "Y");
    try echo_testing.expect(echo.filter(.{ .text_input = "Y" }));
    try echo_testing.expect(!echo.filter(.{ .text_input = "Y" }));

    // A command chord never inserts text, so it never expects an echo.
    const chord: platform.KeyEvent = .{ .action = .press, .codepoint = 'a', .unshifted_codepoint = 'a', .mods = .{ .ctrl = true } };
    echo.recordKeyText(chord, "a");
    try echo_testing.expect(!echo.filter(.{ .text_input = "a" }));
}

test "shift and caps lock presses encode their character once with its echo dropped" {
    var echo: KeyTextEcho = .{};
    var scratch: TextScratch = .{};

    // What the platform now reports for a real Shift+h and for `a` with Caps
    // Lock on: the layout's character, not SDL's unmodified keycode.
    const shifted: platform.KeyEvent = .{ .action = .press, .codepoint = 'H', .unshifted_codepoint = 'h', .mods = .{ .shift = true } };
    const capitals: platform.KeyEvent = .{ .action = .press, .codepoint = 'A', .unshifted_codepoint = 'a', .mods = .{ .caps_lock = true } };
    for ([_]struct { raw: platform.KeyEvent, text: []const u8 }{
        .{ .raw = shifted, .text = "H" },
        .{ .raw = capitals, .text = "A" },
    }) |case| {
        try echo_testing.expect(!echo.filter(.{ .key = case.raw }));
        const press = translate(&scratch, case.raw, false);
        try echo_testing.expectEqualStrings(case.text, press.encoded.text);
        echo.recordTerminalPress(case.raw, press);
        try echo_testing.expect(echo.filter(.{ .text_input = case.text }));
    }
}

test "a press translated while composing records nothing" {
    var echo: KeyTextEcho = .{};
    var scratch: TextScratch = .{};
    const raw: platform.KeyEvent = .{ .action = .press, .codepoint = 'a' };
    _ = echo.filter(.{ .key = raw });
    echo.recordTerminalPress(raw, translate(&scratch, raw, true));
    try echo_testing.expect(!echo.filter(.{ .text_input = "a" }));
}

test "configured chord spellings parse to the same chords the defaults use" {
    const testing = std.testing;
    try testing.expect(chordEql(.{ .key = .{ .character = 't' }, .modifiers = .{ .ctrl = true, .shift = true } }, try parseChord("ctrl+shift+t")));
    try testing.expect(chordEql(.{ .key = .{ .character = 't' }, .modifiers = .{ .ctrl = true, .shift = true } }, try parseChord("Shift+CTRL+T")));
    try testing.expect(chordEql(.{ .key = .{ .character = '`' }, .modifiers = .{ .ctrl = true } }, try parseChord("ctrl+`")));
    try testing.expect(chordEql(.{ .key = .{ .character = '`' }, .modifiers = .{ .super = true, .shift = true } }, try parseChord("cmd+shift+backtick")));
    try testing.expect(chordEql(.{ .key = .{ .character = ',' }, .modifiers = .{ .super = true } }, try parseChord("command+,")));
    try testing.expect(chordEql(.{ .key = .{ .character = '+' }, .modifiers = .{ .ctrl = true } }, try parseChord("ctrl+plus")));
    try testing.expect(chordEql(.{ .key = .{ .character = '=' }, .modifiers = .{ .ctrl = true } }, try parseChord("ctrl+equal")));
    try testing.expect(chordEql(.{ .key = .{ .character = ' ' }, .modifiers = .{ .alt = true } }, try parseChord("option+space")));
    try testing.expect(chordEql(.{ .key = .{ .named = .f10 }, .modifiers = .{ .shift = true } }, try parseChord("shift+F10")));
    try testing.expect(chordEql(.{ .key = .{ .named = .page_up }, .modifiers = .{ .ctrl = true } }, try parseChord("ctrl+pageup")));
    try testing.expect(chordEql(.{ .key = .{ .named = .page_down }, .modifiers = .{ .ctrl = true } }, try parseChord("control+page_down")));
    try testing.expect(chordEql(.{ .key = .{ .named = .escape } }, try parseChord("esc")));
    try testing.expect(chordEql(.{ .key = .{ .named = .enter }, .modifiers = .{ .alt = true } }, try parseChord(" alt + return ")));
    try testing.expect(chordEql(.{ .key = .{ .character = 0xe9 }, .modifiers = .{ .alt = true } }, try parseChord("alt+\u{e9}")));
    // Lock modifiers never take part in chord identity.
    try testing.expect(chordEql(.{ .key = .{ .character = 'a' }, .modifiers = .{ .ctrl = true, .caps_lock = true } }, try parseChord("ctrl+a")));
    try testing.expect(!chordEql(try parseChord("ctrl+a"), try parseChord("ctrl+shift+a")));
    try testing.expect(!chordEql(try parseChord("ctrl+a"), try parseChord("ctrl+b")));

    try testing.expectError(error.EmptyChord, parseChord(""));
    try testing.expectError(error.MissingKey, parseChord("ctrl+"));
    try testing.expectError(error.MissingKey, parseChord("ctrl++"));
    try testing.expectError(error.MissingKey, parseChord("+"));
    try testing.expectError(error.MissingKey, parseChord("ctrl++t"));
    try testing.expectError(error.UnknownModifier, parseChord("hyper+t"));
    try testing.expectError(error.UnknownModifier, parseChord("t+t"));
    try testing.expectError(error.DuplicateModifier, parseChord("ctrl+control+t"));
    try testing.expectError(error.UnknownKey, parseChord("ctrl+tt"));
    try testing.expectError(error.UnknownKey, parseChord("ctrl+f13"));
    try testing.expectError(error.UnknownKey, parseChord("ctrl+\x01"));
    try testing.expectError(error.UnknownKey, parseChord("ctrl+\xff"));
}

test "every default chord survives a round trip through its configured spelling" {
    const testing = std.testing;
    for ([_]PlatformProfile{ .macos, .linux_windows }) |profile| {
        for (defaultBindings(profile)) |binding| {
            var buffer: [64]u8 = undefined;
            var used: usize = 0;
            const modifiers = binding.chord.modifiers;
            for ([_]struct { on: bool, text: []const u8 }{
                .{ .on = modifiers.ctrl, .text = "ctrl+" },
                .{ .on = modifiers.alt, .text = "alt+" },
                .{ .on = modifiers.super, .text = "super+" },
                .{ .on = modifiers.shift, .text = "shift+" },
            }) |part| if (part.on) {
                @memcpy(buffer[used..][0..part.text.len], part.text);
                used += part.text.len;
            };
            switch (binding.chord.key) {
                .named => |named| {
                    const name = @tagName(named);
                    @memcpy(buffer[used..][0..name.len], name);
                    used += name.len;
                },
                .character => |codepoint| used += try std.unicode.utf8Encode(codepoint, buffer[used..]),
            }
            try testing.expect(chordEql(binding.chord, try parseChord(buffer[0..used])));
        }
    }
}

test "overrides replace, add and unbind while defaults stay borrowed" {
    const testing = std.testing;
    const defaults = defaultBindings(.linux_windows);
    const new_palette = try parseChord("ctrl+alt+p");
    const goto_arguments = [_]Argument{.{ .name = "index", .value = "4" }};
    var table = try buildBindings(testing.allocator, defaults, &.{
        .{ .chord = try parseChord("ctrl+shift+p"), .action = null },
        .{ .chord = new_palette, .action = "palette.open" },
        .{ .chord = try parseChord("ctrl+shift+t"), .action = "tab.goto", .arguments = &goto_arguments },
        .{ .chord = try parseChord("ctrl+`"), .action = "scratchpad.toggle-90" },
        .{ .chord = try parseChord("f7"), .action = null },
    });
    defer table.deinit();

    try testing.expectEqual(defaults.len, table.bindings.len);
    var palette_count: usize = 0;
    for (table.bindings) |binding| {
        if (std.mem.eql(u8, binding.action, "palette.open")) {
            palette_count += 1;
            try testing.expect(chordEql(binding.chord, new_palette));
        }
    }
    try testing.expectEqual(@as(usize, 1), palette_count);

    // A replaced chord keeps its position, so the palette lists bindings in a stable order.
    const new_tab_index = for (defaults, 0..) |binding, index| {
        if (std.mem.eql(u8, binding.action, "tab.new")) break index;
    } else unreachable;
    try testing.expectEqualStrings("tab.goto", table.bindings[new_tab_index].action);
    try testing.expectEqualStrings("index", table.bindings[new_tab_index].arguments[0].name);
    try testing.expectEqualStrings("4", table.bindings[new_tab_index].arguments[0].value);
    for (table.bindings) |binding| try testing.expect(!std.mem.eql(u8, binding.action, "tab.new"));

    // Both scratchpad bindings are configurable: the 50 percent chord now opens 90 percent.
    var ninety: usize = 0;
    for (table.bindings) |binding| {
        if (std.mem.eql(u8, binding.action, "scratchpad.toggle-90")) ninety += 1;
        try testing.expect(!std.mem.eql(u8, binding.action, "scratchpad.toggle-50"));
    }
    try testing.expectEqual(@as(usize, 2), ninety);
}

test "a pressed chord is spelled so it parses back to itself and finds its binding" {
    const testing = std.testing;
    for ([_]PlatformProfile{ .macos, .linux_windows }) |profile| {
        for (defaultBindings(profile)) |binding| {
            var buffer: [64]u8 = undefined;
            const spelling = try formatChordSpelling(&buffer, binding.chord);
            try testing.expect(chordEql(binding.chord, try parseChord(spelling)));
            const found = findBinding(defaultBindings(profile), binding.chord).?;
            try testing.expect(chordEql(found.chord, binding.chord));
        }
    }
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("ctrl+alt+super+shift+page_up", try formatChordSpelling(&buffer, .{ .key = .{ .named = .page_up }, .modifiers = .{ .ctrl = true, .alt = true, .super = true, .shift = true, .caps_lock = true } }));
    try testing.expectEqualStrings("ctrl+plus", try formatChordSpelling(&buffer, .{ .key = .{ .character = '+' }, .modifiers = .{ .ctrl = true } }));
    try testing.expectEqualStrings("ctrl+equal", try formatChordSpelling(&buffer, .{ .key = .{ .character = '=' }, .modifiers = .{ .ctrl = true } }));
    try testing.expectEqualStrings("alt+space", try formatChordSpelling(&buffer, .{ .key = .{ .character = ' ' }, .modifiers = .{ .alt = true } }));
    try testing.expectEqualStrings("alt+\u{e9}", try formatChordSpelling(&buffer, .{ .key = .{ .character = 0xe9 }, .modifiers = .{ .alt = true } }));
    var tiny: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, formatChordSpelling(&tiny, .{ .key = .{ .named = .f10 }, .modifiers = .{ .ctrl = true } }));

    // The press the user makes is the chord, whatever character the layout shifted it to.
    const pressed = chordOf(symbolKey(',', '<', .{ .ctrl = true, .shift = true })).?;
    try testing.expect(chordEql(pressed, try parseChord("ctrl+shift+,")));
    try testing.expect(chordOf(.{ .action = .press }) == null);
    try testing.expectEqualStrings("palette.open", findBinding(defaultBindings(.linux_windows), try parseChord("ctrl+shift+p")).?.action);
    try testing.expect(findBinding(defaultBindings(.linux_windows), try parseChord("ctrl+alt+k")) == null);

    try testing.expect(chordTypesText(try parseChord("k")));
    try testing.expect(chordTypesText(try parseChord("shift+k")));
    try testing.expect(!chordTypesText(try parseChord("ctrl+k")));
    try testing.expect(!chordTypesText(try parseChord("alt+shift+k")));
    try testing.expect(!chordTypesText(try parseChord("f5")));
}

fn routeThrough(bindings: []const Binding, raw: platform.KeyEvent) Route {
    var storage: [4]BindingKey = undefined;
    var state = BindingState.init(&storage);
    var scratch: TextScratch = .{};
    return resolve(&state, raw, translate(&scratch, raw, false), bindings);
}

test "a rebuilt table routes the new chord and leaves an unbound chord to the terminal" {
    const testing = std.testing;
    var table = try buildBindings(testing.allocator, defaultBindings(.linux_windows), &.{
        .{ .chord = try parseChord("ctrl+shift+p"), .action = null },
        .{ .chord = try parseChord("ctrl+alt+p"), .action = "palette.open" },
    });
    defer table.deinit();

    switch (routeThrough(table.bindings, letterKey('p', .{ .ctrl = true, .alt = true }, .press))) {
        .action => |request| try testing.expectEqualStrings("palette.open", request.action),
        else => return error.TestExpectedEqual,
    }
    switch (routeThrough(table.bindings, letterKey('p', .{ .ctrl = true, .shift = true }, .press))) {
        .terminal => {},
        else => return error.TestExpectedEqual,
    }
}

fn keybindTestHandler(_: *anyopaque, _: Invocation) anyerror!void {}

test "keybind arguments follow the palette contract or the shipped defaults" {
    const testing = std.testing;
    const directions = [_]PaletteChoice{
        .{ .label = "Right", .value = "right" },
        .{ .label = "Down", .value = "down" },
    };
    var storage: [6]ActionDefinition = undefined;
    var registry = Registry.init(&storage);
    try registry.register(.{ .name = "tab.new", .label = "New tab", .handler = keybindTestHandler });
    try registry.register(.{ .name = "pane.split", .label = "Split pane", .handler = keybindTestHandler, .palette = .{ .argument = .{ .choices = .{
        .name = "direction",
        .prompt = "Split",
        .values = &directions,
    } } } });
    try registry.register(.{ .name = "tab.goto", .label = "Go to tab", .handler = keybindTestHandler, .palette = .{ .argument = .{ .input = .{
        .name = "index",
        .prompt = "Tab number",
    } } } });
    try registry.register(.{ .name = "palette.open", .label = "Open palette", .handler = keybindTestHandler, .palette = null });
    try registry.register(.{ .name = "tab.activate", .label = "Activate tab", .handler = keybindTestHandler, .palette = null });
    const defaults = defaultBindings(.linux_windows);

    try testing.expectEqual(@as(?Argument, null), try keybindArgument(&registry, defaults, "tab.new", null));
    try testing.expectError(error.UnexpectedArgument, keybindArgument(&registry, defaults, "tab.new", "x"));
    const split = (try keybindArgument(&registry, defaults, "pane.split", "down")).?;
    try testing.expectEqualStrings("direction", split.name);
    try testing.expectEqualStrings("down", split.value);
    try testing.expectError(error.InvalidArgument, keybindArgument(&registry, defaults, "pane.split", "sideways"));
    try testing.expectError(error.MissingArgument, keybindArgument(&registry, defaults, "pane.split", null));
    const goto = (try keybindArgument(&registry, defaults, "tab.goto", "3")).?;
    try testing.expectEqualStrings("index", goto.name);
    try testing.expectError(error.MissingArgument, keybindArgument(&registry, defaults, "tab.goto", null));
    // Not palette-visible, but shipped with a default chord: bindable, no argument.
    try testing.expectEqual(@as(?Argument, null), try keybindArgument(&registry, defaults, "palette.open", null));
    try testing.expectError(error.NotBindable, keybindArgument(&registry, defaults, "tab.activate", null));
    try testing.expectError(error.UnknownAction, keybindArgument(&registry, defaults, "no.such", null));
}
