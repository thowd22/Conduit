//! A minimal, bounded D-Bus client: the wire format, message framing, the
//! SASL EXTERNAL handshake and a Unix-socket connection.
//!
//! Only what the AT-SPI bridge needs is implemented, and every input is
//! bounded: a message larger than `max_message_bytes`, a container nested
//! deeper than `max_depth`, or a header that breaks the specification is
//! refused with an error rather than trusted. Malformed bytes from the bus
//! never crash the caller.
//!
//! Marshalling always produces little-endian messages; parsing accepts both
//! byte orders. Alignment is relative to the start of the buffer being
//! written or read. A body always starts at an 8-aligned message offset, so
//! body-relative alignment is identical to message-relative alignment.
//!
//! The `Connection` uses raw Linux syscalls (`std.os.linux`): the AT-SPI bus
//! exists only on Linux and other freedesktop systems, and it is the only
//! caller.

const std = @import("std");
const builtin = @import("builtin");

/// The largest message, header plus body, this client sends or accepts. The
/// D-Bus limit is 128 MiB; nothing the bridge exchanges comes close to this.
pub const max_message_bytes: usize = 4 << 20;

/// Deepest container nesting accepted by `Reader.skip`. The specification
/// allows 32 arrays plus 32 structs; 64 covers both.
pub const max_depth: u32 = 64;

/// Why bytes could not be written or read as D-Bus data.
pub const Error = error{
    /// The output buffer is full.
    MessageTooLarge,
    /// The input is truncated, misaligned, or breaks the wire format.
    Malformed,
    /// A string holds a NUL byte or is not UTF-8, or a path or signature is
    /// not well formed.
    InvalidString,
};

/// D-Bus message types.
pub const MessageType = enum(u8) {
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
    _,
};

/// The flag a caller sets when it does not want a reply.
pub const flag_no_reply_expected: u8 = 0x1;

/// Byte order of a received message.
pub const Endian = enum { little, big };

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// Whether `s` may be sent as a D-Bus string: UTF-8 without NUL.
pub fn validString(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(s);
}

/// Whether `path` is a well-formed object path.
pub fn validObjectPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var previous_slash = true;
    for (path[1..]) |c| {
        if (c == '/') {
            if (previous_slash) return false;
            previous_slash = true;
            continue;
        }
        previous_slash = false;
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// The length of the first complete type at the start of `sig`, or
/// `error.InvalidString` if it is not one.
pub fn completeTypeLen(sig: []const u8) Error!usize {
    return completeTypeLenDepth(sig, 0);
}

fn completeTypeLenDepth(sig: []const u8, depth: u32) Error!usize {
    if (sig.len == 0 or depth > max_depth) return error.InvalidString;
    switch (sig[0]) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'v', 'h' => return 1,
        'a' => {
            if (sig.len > 1 and sig[1] == '{') {
                // A dict entry: a basic key and one complete value.
                if (sig.len < 5) return error.InvalidString;
                if (!isBasic(sig[2])) return error.InvalidString;
                const value_len = try completeTypeLenDepth(sig[3..], depth + 1);
                const close = 3 + value_len;
                if (close >= sig.len or sig[close] != '}') return error.InvalidString;
                return close + 1;
            }
            return 1 + try completeTypeLenDepth(sig[1..], depth + 1);
        },
        '(' => {
            var pos: usize = 1;
            if (pos >= sig.len or sig[pos] == ')') return error.InvalidString;
            while (pos < sig.len and sig[pos] != ')') {
                pos += try completeTypeLenDepth(sig[pos..], depth + 1);
            }
            if (pos >= sig.len) return error.InvalidString;
            return pos + 1;
        },
        else => return error.InvalidString,
    }
}

fn isBasic(c: u8) bool {
    return switch (c) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h' => true,
        else => false,
    };
}

/// Whether `sig` is a sequence of complete types no longer than 255 bytes.
pub fn validSignature(sig: []const u8) bool {
    if (sig.len > 255) return false;
    var pos: usize = 0;
    while (pos < sig.len) {
        pos += completeTypeLen(sig[pos..]) catch return false;
    }
    return true;
}

fn typeAlignment(code: u8) usize {
    return switch (code) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

// ---------------------------------------------------------------------------
// Writer
// ---------------------------------------------------------------------------

/// A little-endian marshaller into a caller-owned fixed buffer. It allocates
/// nothing; running out of space is `error.MessageTooLarge`.
pub const Writer = struct {
    buf: []u8,
    len: usize = 0,

    /// A writer over `buf`, starting empty.
    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    /// The bytes written so far.
    pub fn written(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }

    fn reserve(self: *Writer, n: usize) Error![]u8 {
        if (n > self.buf.len - self.len) return error.MessageTooLarge;
        const out = self.buf[self.len .. self.len + n];
        self.len += n;
        return out;
    }

    /// Write zero bytes up to the next multiple of `alignment`.
    pub fn pad(self: *Writer, alignment: usize) Error!void {
        const target = alignUp(self.len, alignment);
        const zeros = try self.reserve(target - self.len);
        @memset(zeros, 0);
    }

    /// Append raw bytes without alignment.
    pub fn raw(self: *Writer, bytes: []const u8) Error!void {
        @memcpy(try self.reserve(bytes.len), bytes);
    }

    pub fn byte(self: *Writer, value: u8) Error!void {
        (try self.reserve(1))[0] = value;
    }

    pub fn boolean(self: *Writer, value: bool) Error!void {
        try self.uint32(@intFromBool(value));
    }

    pub fn int16(self: *Writer, value: i16) Error!void {
        try self.pad(2);
        std.mem.writeInt(i16, (try self.reserve(2))[0..2], value, .little);
    }

    pub fn uint32(self: *Writer, value: u32) Error!void {
        try self.pad(4);
        std.mem.writeInt(u32, (try self.reserve(4))[0..4], value, .little);
    }

    pub fn int32(self: *Writer, value: i32) Error!void {
        try self.uint32(@bitCast(value));
    }

    pub fn uint64(self: *Writer, value: u64) Error!void {
        try self.pad(8);
        std.mem.writeInt(u64, (try self.reserve(8))[0..8], value, .little);
    }

    pub fn double(self: *Writer, value: f64) Error!void {
        try self.uint64(@bitCast(value));
    }

    /// A string (`s`): UTF-8 without NUL, refused otherwise.
    pub fn string(self: *Writer, s: []const u8) Error!void {
        if (!validString(s)) return error.InvalidString;
        try self.stringBytes(s);
    }

    fn stringBytes(self: *Writer, s: []const u8) Error!void {
        if (s.len > std.math.maxInt(u32)) return error.MessageTooLarge;
        try self.uint32(@intCast(s.len));
        try self.raw(s);
        try self.byte(0);
    }

    /// An object path (`o`).
    pub fn objectPath(self: *Writer, path: []const u8) Error!void {
        if (!validObjectPath(path)) return error.InvalidString;
        try self.stringBytes(path);
    }

    /// A signature (`g`).
    pub fn signature(self: *Writer, sig: []const u8) Error!void {
        if (!validSignature(sig)) return error.InvalidString;
        try self.byte(@intCast(sig.len));
        try self.raw(sig);
        try self.byte(0);
    }

    /// Open an array whose elements align to `element_alignment`. Close it
    /// with `endArray`, passing the returned mark.
    pub fn beginArray(self: *Writer, element_alignment: usize) Error!ArrayMark {
        try self.pad(4);
        const len_pos = self.len;
        _ = try self.reserve(4);
        try self.pad(element_alignment);
        return .{ .len_pos = len_pos, .start = self.len };
    }

    /// Patch the array length now that its elements are written.
    pub fn endArray(self: *Writer, mark: ArrayMark) Error!void {
        const size = self.len - mark.start;
        if (size > 64 << 20) return error.MessageTooLarge;
        std.mem.writeInt(u32, self.buf[mark.len_pos..][0..4], @intCast(size), .little);
    }

    /// Open a struct or dict entry: both align to 8.
    pub fn beginStruct(self: *Writer) Error!void {
        try self.pad(8);
    }

    /// Write a variant's signature; the caller then writes one value of it.
    pub fn beginVariant(self: *Writer, sig: []const u8) Error!void {
        if (sig.len == 0 or (completeTypeLen(sig) catch 0) != sig.len) return error.InvalidString;
        try self.signature(sig);
    }

    /// A `(so)` object reference.
    pub fn reference(self: *Writer, bus_name: []const u8, path: []const u8) Error!void {
        try self.beginStruct();
        try self.string(bus_name);
        try self.objectPath(path);
    }
};

/// Where an open array's length lives and where its elements begin.
pub const ArrayMark = struct {
    len_pos: usize,
    start: usize,
};

// ---------------------------------------------------------------------------
// Reader
// ---------------------------------------------------------------------------

/// An unmarshaller over borrowed bytes. Returned slices borrow from `buf`.
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,
    endian: Endian = .little,

    /// A reader over `buf` in byte order `endian`.
    pub fn init(buf: []const u8, endian: Endian) Reader {
        return .{ .buf = buf, .endian = endian };
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.buf.len - self.pos) return error.Malformed;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    /// Skip padding to `alignment`. The specification requires padding to be
    /// zero, so non-zero padding is malformed.
    pub fn alignTo(self: *Reader, alignment: usize) Error!void {
        const target = alignUp(self.pos, alignment);
        if (target > self.buf.len) return error.Malformed;
        for (self.buf[self.pos..target]) |b| if (b != 0) return error.Malformed;
        self.pos = target;
    }

    fn order(self: *const Reader) std.builtin.Endian {
        return if (self.endian == .little) .little else .big;
    }

    pub fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn boolean(self: *Reader) Error!bool {
        const value = try self.uint32();
        if (value > 1) return error.Malformed;
        return value == 1;
    }

    pub fn int16(self: *Reader) Error!i16 {
        try self.alignTo(2);
        return std.mem.readInt(i16, (try self.take(2))[0..2], self.order());
    }

    pub fn uint32(self: *Reader) Error!u32 {
        try self.alignTo(4);
        return std.mem.readInt(u32, (try self.take(4))[0..4], self.order());
    }

    pub fn int32(self: *Reader) Error!i32 {
        return @bitCast(try self.uint32());
    }

    pub fn uint64(self: *Reader) Error!u64 {
        try self.alignTo(8);
        return std.mem.readInt(u64, (try self.take(8))[0..8], self.order());
    }

    pub fn double(self: *Reader) Error!f64 {
        return @bitCast(try self.uint64());
    }

    fn stringBytes(self: *Reader) Error![]const u8 {
        const len = try self.uint32();
        if (len > self.buf.len) return error.Malformed;
        const bytes = try self.take(len);
        if ((try self.byte()) != 0) return error.Malformed;
        return bytes;
    }

    /// A string (`s`), validated.
    pub fn string(self: *Reader) Error![]const u8 {
        const s = try self.stringBytes();
        if (!validString(s)) return error.Malformed;
        return s;
    }

    /// An object path (`o`), validated.
    pub fn objectPath(self: *Reader) Error![]const u8 {
        const s = try self.stringBytes();
        if (!validObjectPath(s)) return error.Malformed;
        return s;
    }

    /// A signature (`g`), validated.
    pub fn signature(self: *Reader) Error![]const u8 {
        const len = try self.byte();
        const s = try self.take(len);
        if ((try self.byte()) != 0) return error.Malformed;
        if (!validSignature(s)) return error.Malformed;
        return s;
    }

    /// Open an array of elements aligned to `element_alignment`; returns the
    /// offset one past its last element. Iterate `while (r.pos < end)`.
    pub fn beginArray(self: *Reader, element_alignment: usize) Error!usize {
        const len = try self.uint32();
        if (len > 64 << 20) return error.Malformed;
        try self.alignTo(element_alignment);
        if (len > self.buf.len - self.pos) return error.Malformed;
        return self.pos + len;
    }

    pub fn beginStruct(self: *Reader) Error!void {
        try self.alignTo(8);
    }

    /// Skip one value of the complete type `sig`.
    pub fn skip(self: *Reader, sig: []const u8) Error!void {
        return self.skipDepth(sig, 0);
    }

    fn skipDepth(self: *Reader, sig: []const u8, depth: u32) Error!void {
        if (depth > max_depth) return error.Malformed;
        const type_len = completeTypeLen(sig) catch return error.Malformed;
        if (type_len != sig.len) return error.Malformed;
        switch (sig[0]) {
            'y' => _ = try self.byte(),
            'b' => _ = try self.boolean(),
            'n', 'q' => _ = try self.int16(),
            'i', 'u', 'h' => _ = try self.uint32(),
            'x', 't', 'd' => _ = try self.uint64(),
            's' => _ = try self.string(),
            'o' => _ = try self.objectPath(),
            'g' => _ = try self.signature(),
            'v' => {
                const inner = try self.signature();
                if (inner.len == 0 or (completeTypeLen(inner) catch 0) != inner.len) return error.Malformed;
                try self.skipDepth(inner, depth + 1);
            },
            'a' => {
                const element = sig[1..];
                const end = try self.beginArray(typeAlignment(element[0]));
                while (self.pos < end) {
                    if (element[0] == '{') {
                        try self.beginStruct();
                        try self.skipDepth(element[1..2], depth + 1);
                        try self.skipDepth(element[2 .. element.len - 1], depth + 1);
                    } else {
                        try self.skipDepth(element, depth + 1);
                    }
                }
                if (self.pos != end) return error.Malformed;
            },
            '(' => {
                try self.beginStruct();
                var pos: usize = 1;
                while (sig[pos] != ')') {
                    const len = completeTypeLen(sig[pos..]) catch return error.Malformed;
                    try self.skipDepth(sig[pos .. pos + len], depth + 1);
                    pos += len;
                }
            },
            else => return error.Malformed,
        }
    }
};

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

/// Header field codes.
const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
    _,
};

/// A parsed message. Every slice borrows from the bytes it was parsed from.
pub const Message = struct {
    type: MessageType,
    flags: u8 = 0,
    serial: u32,
    endian: Endian = .little,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
    body: []const u8 = "",

    /// A reader positioned at the start of the body.
    pub fn bodyReader(self: *const Message) Reader {
        return Reader.init(self.body, self.endian);
    }

    /// Whether the message is a call to `interface.member`.
    pub fn isCall(self: *const Message, interface: []const u8, member: []const u8) bool {
        if (self.type != .method_call) return false;
        const m = self.member orelse return false;
        if (!std.mem.eql(u8, m, member)) return false;
        // The interface is optional on a call; a call without one matches by
        // member alone, as the specification permits.
        const i = self.interface orelse return true;
        return std.mem.eql(u8, i, interface);
    }

    pub fn wantsReply(self: *const Message) bool {
        return self.type == .method_call and (self.flags & flag_no_reply_expected) == 0;
    }
};

/// The total length of the message that starts with `prefix`, or null when
/// fewer than 16 bytes are available. Refuses lengths above
/// `max_message_bytes`.
pub fn frameLength(prefix: []const u8) Error!?usize {
    if (prefix.len < 16) return null;
    const order: std.builtin.Endian = switch (prefix[0]) {
        'l' => .little,
        'B' => .big,
        else => return error.Malformed,
    };
    if (prefix[3] != 1) return error.Malformed;
    const body_len = std.mem.readInt(u32, prefix[4..8], order);
    const fields_len = std.mem.readInt(u32, prefix[12..16], order);
    if (body_len > max_message_bytes or fields_len > max_message_bytes) return error.Malformed;
    const total = alignUp(16 + @as(usize, fields_len), 8) + body_len;
    if (total > max_message_bytes) return error.Malformed;
    return total;
}

/// Parse one complete message. `bytes` must be exactly one frame.
pub fn parse(bytes: []const u8) Error!Message {
    const total = (try frameLength(bytes)) orelse return error.Malformed;
    if (total != bytes.len) return error.Malformed;
    var r = Reader.init(bytes, if (bytes[0] == 'l') .little else .big);
    _ = try r.byte();
    const kind: MessageType = @enumFromInt(try r.byte());
    const flags = try r.byte();
    _ = try r.byte();
    const body_len = try r.uint32();
    const serial = try r.uint32();
    if (serial == 0) return error.Malformed;
    var message: Message = .{ .type = kind, .flags = flags, .serial = serial, .endian = r.endian };

    const end = try r.beginArray(8);
    while (r.pos < end) {
        try r.beginStruct();
        const code: Field = @enumFromInt(try r.byte());
        const sig = try r.signature();
        const expect: ?[]const u8 = switch (code) {
            .path => "o",
            .interface, .member, .error_name, .destination, .sender => "s",
            .reply_serial, .unix_fds => "u",
            .signature => "g",
            _ => null,
        };
        if (expect) |e| {
            if (!std.mem.eql(u8, sig, e)) return error.Malformed;
        } else {
            if (sig.len == 0 or (completeTypeLen(sig) catch 0) != sig.len) return error.Malformed;
            try r.skip(sig);
            continue;
        }
        switch (code) {
            .path => message.path = try r.objectPath(),
            .interface => message.interface = try r.string(),
            .member => message.member = try r.string(),
            .error_name => message.error_name = try r.string(),
            .destination => message.destination = try r.string(),
            .sender => message.sender = try r.string(),
            .reply_serial => message.reply_serial = try r.uint32(),
            .unix_fds => {
                // The bridge never negotiates descriptor passing, so a
                // message that claims to carry descriptors is not for it.
                if ((try r.uint32()) != 0) return error.Malformed;
            },
            .signature => message.signature = try r.signature(),
            _ => unreachable, // handled above by the `expect == null` branch
        }
    }
    if (r.pos != end) return error.Malformed;
    try r.alignTo(8);
    if (bytes.len - r.pos != body_len) return error.Malformed;
    message.body = bytes[r.pos..];

    switch (kind) {
        .method_call => if (message.path == null or message.member == null) return error.Malformed,
        .signal => if (message.path == null or message.interface == null or message.member == null) return error.Malformed,
        .method_return => if (message.reply_serial == null) return error.Malformed,
        .@"error" => if (message.reply_serial == null or message.error_name == null) return error.Malformed,
        _ => return error.Malformed,
    }
    if (message.body.len != 0 and message.signature.len == 0) return error.Malformed;
    return message;
}

/// What `encode` puts in a header.
pub const Header = struct {
    type: MessageType,
    flags: u8 = 0,
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    signature: []const u8 = "",
};

/// Encode a complete message: `header` plus an already-marshalled `body`
/// whose signature is `header.signature`.
pub fn encode(out: *Writer, header: Header, body: []const u8) Error!void {
    const start = out.len;
    // Alignment inside the message is relative to its first byte. Messages
    // are only ever encoded at an 8-aligned offset.
    if (start % 8 != 0) return error.Malformed;
    if (body.len > max_message_bytes) return error.MessageTooLarge;
    try out.byte('l');
    try out.byte(@intFromEnum(header.type));
    try out.byte(header.flags);
    try out.byte(1);
    try out.uint32(@intCast(body.len));
    try out.uint32(header.serial);
    const mark = try out.beginArray(8);
    if (header.path) |v| try fieldString(out, .path, "o", v);
    if (header.interface) |v| try fieldString(out, .interface, "s", v);
    if (header.member) |v| try fieldString(out, .member, "s", v);
    if (header.error_name) |v| try fieldString(out, .error_name, "s", v);
    if (header.reply_serial) |v| {
        try out.beginStruct();
        try out.byte(@intFromEnum(Field.reply_serial));
        try out.signature("u");
        try out.uint32(v);
    }
    if (header.destination) |v| try fieldString(out, .destination, "s", v);
    if (header.signature.len != 0) {
        try out.beginStruct();
        try out.byte(@intFromEnum(Field.signature));
        try out.signature("g");
        try out.signature(header.signature);
    }
    try out.endArray(mark);
    try out.pad(8);
    try out.raw(body);
    if (out.len - start > max_message_bytes) return error.MessageTooLarge;
}

fn fieldString(out: *Writer, code: Field, sig: []const u8, value: []const u8) Error!void {
    try out.beginStruct();
    try out.byte(@intFromEnum(code));
    try out.signature(sig);
    if (sig[0] == 'o') try out.objectPath(value) else try out.string(value);
}

// ---------------------------------------------------------------------------
// Addresses
// ---------------------------------------------------------------------------

/// A Unix socket address from a D-Bus address string.
pub const UnixAddress = struct {
    /// The socket path, or the abstract name without its leading NUL.
    bytes: [107]u8 = undefined,
    len: usize = 0,
    abstract: bool = false,

    pub fn name(self: *const UnixAddress) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// The first `unix:path=` or `unix:abstract=` entry of a `;`-separated D-Bus
/// address list, with `%XX` escapes decoded.
pub fn parseAddress(address: []const u8) error{UnsupportedAddress}!UnixAddress {
    var entries = std.mem.splitScalar(u8, address, ';');
    while (entries.next()) |entry| {
        if (!std.mem.startsWith(u8, entry, "unix:")) continue;
        var pairs = std.mem.splitScalar(u8, entry["unix:".len..], ',');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            const key = pair[0..eq];
            const abstract = std.mem.eql(u8, key, "abstract");
            if (!abstract and !std.mem.eql(u8, key, "path")) continue;
            var out: UnixAddress = .{ .abstract = abstract };
            out.len = unescape(pair[eq + 1 ..], &out.bytes) catch return error.UnsupportedAddress;
            if (out.len == 0) return error.UnsupportedAddress;
            return out;
        }
    }
    return error.UnsupportedAddress;
}

fn unescape(value: []const u8, out: []u8) error{Invalid}!usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < value.len) : (len += 1) {
        if (len >= out.len) return error.Invalid;
        if (value[i] == '%') {
            if (i + 3 > value.len) return error.Invalid;
            out[len] = std.fmt.parseInt(u8, value[i + 1 .. i + 3], 16) catch return error.Invalid;
            if (out[len] == 0) return error.Invalid;
            i += 3;
        } else {
            out[len] = value[i];
            i += 1;
        }
    }
    return len;
}

// ---------------------------------------------------------------------------
// SASL
// ---------------------------------------------------------------------------

/// Why authentication failed.
pub const AuthError = error{ AuthRejected, AuthProtocol };

/// Run the client side of SASL EXTERNAL over `transport`, which provides
/// `writeAll([]const u8) !void` and `readByte() !?u8` (null at end of
/// stream). Lines are bounded to 512 bytes. On success the next byte on the
/// transport is the first byte of the server's first message.
pub fn authenticate(transport: anytype, uid: u32) !void {
    var decimal_buf: [16]u8 = undefined;
    const decimal = std.fmt.bufPrint(&decimal_buf, "{d}", .{uid}) catch unreachable; // u32 fits in 10 digits
    var line_buf: [64]u8 = undefined;
    var w = Writer.init(&line_buf);
    w.raw("\x00AUTH EXTERNAL ") catch unreachable; // fixed sizes fit the 64-byte buffer
    for (decimal) |digit| {
        var hex: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x:0>2}", .{digit}) catch unreachable; // two hex digits per byte
        w.raw(&hex) catch unreachable; // at most 20 bytes for 10 digits
    }
    w.raw("\r\n") catch unreachable; // see above
    try transport.writeAll(w.written());

    var reply_buf: [512]u8 = undefined;
    const reply = try readLine(transport, &reply_buf);
    if (std.mem.startsWith(u8, reply, "REJECTED")) return error.AuthRejected;
    if (!std.mem.startsWith(u8, reply, "OK ")) return error.AuthProtocol;
    try transport.writeAll("BEGIN\r\n");
}

fn readLine(transport: anytype, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        const b = (try transport.readByte()) orelse return error.AuthProtocol;
        if (len >= buf.len) return error.AuthProtocol;
        buf[len] = b;
        len += 1;
        if (len >= 2 and buf[len - 2] == '\r' and buf[len - 1] == '\n') return buf[0 .. len - 2];
    }
}

// ---------------------------------------------------------------------------
// Connection (Linux)
// ---------------------------------------------------------------------------

const linux = std.os.linux;

/// Why a connection failed.
pub const ConnectionError = error{
    UnsupportedPlatform,
    UnsupportedAddress,
    ConnectFailed,
    AuthRejected,
    AuthProtocol,
    Disconnected,
    TimedOut,
    WriteFailed,
    ReadFailed,
    CallFailed,
    OutOfMemory,
} || Error;

/// One authenticated bus connection with bounded, allocator-owned read and
/// write buffers. Not thread-safe: one thread owns it.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    fd: i32,
    read_buf: []u8,
    read_len: usize = 0,
    /// Length of the frame `next` last returned, consumed by the next call.
    pending_consume: usize = 0,
    write_buf: []u8,
    serial: u32 = 0,
    unique_name_buf: [255]u8 = undefined,
    unique_name_len: usize = 0,

    /// Connect to `address`, authenticate, and leave the connection ready for
    /// `hello`. `read_capacity` bounds the largest message accepted and
    /// `write_capacity` the largest sent (half of it holds a scratch body).
    pub fn open(
        allocator: std.mem.Allocator,
        address: []const u8,
        read_capacity: usize,
        write_capacity: usize,
    ) ConnectionError!Connection {
        if (builtin.os.tag != .linux) return error.UnsupportedPlatform;
        const parsed = parseAddress(address) catch return error.UnsupportedAddress;
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.ConnectFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);

        var sa: linux.sockaddr.un = .{ .path = @splat(0) };
        const offset: usize = if (parsed.abstract) 1 else 0;
        @memcpy(sa.path[offset .. offset + parsed.len], parsed.name());
        const sa_len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + offset + parsed.len +
            @as(usize, if (parsed.abstract) 0 else 1));
        if (linux.errno(linux.connect(fd, &sa, sa_len)) != .SUCCESS) return error.ConnectFailed;

        // A stalled peer must not hold the worker forever on a write.
        const timeout: linux.timeval = .{ .sec = 2, .usec = 0 };
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));

        var transport: FdTransport = .{ .fd = fd };
        authenticate(&transport, linux.getuid()) catch |err| switch (err) {
            error.AuthRejected => return error.AuthRejected,
            else => return error.AuthProtocol,
        };

        const read_buf = try allocator.alloc(u8, @min(read_capacity, max_message_bytes));
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, @min(write_capacity, max_message_bytes));
        return .{ .allocator = allocator, .fd = fd, .read_buf = read_buf, .write_buf = write_buf };
    }

    pub fn close(self: *Connection) void {
        _ = linux.close(self.fd);
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.* = undefined;
    }

    /// The bus-assigned unique name, empty before `hello`.
    pub fn uniqueName(self: *const Connection) []const u8 {
        return self.unique_name_buf[0..self.unique_name_len];
    }

    pub fn nextSerial(self: *Connection) u32 {
        self.serial +%= 1;
        if (self.serial == 0) self.serial = 1;
        return self.serial;
    }

    /// Send a complete encoded message.
    pub fn sendRaw(self: *Connection, bytes: []const u8) ConnectionError!void {
        var transport: FdTransport = .{ .fd = self.fd };
        transport.writeAll(bytes) catch return error.WriteFailed;
    }

    /// Encode `header` and `body` into the write buffer and send them.
    pub fn send(self: *Connection, header: Header, body: []const u8) ConnectionError!void {
        var w = Writer.init(self.write_buf);
        try encode(&w, header, body);
        try self.sendRaw(w.written());
    }

    /// The write buffer, for callers that marshal a body in place before
    /// `send` copies it. Bodies are marshalled into a separate buffer.
    pub fn bodyScratch(self: *Connection) []u8 {
        // The second half of the write buffer holds a body while the first
        // half receives the encoded message.
        return self.write_buf[self.write_buf.len / 2 ..];
    }

    /// Encode a message whose body lives in `bodyScratch()`.
    pub fn sendScratch(self: *Connection, header: Header, body_len: usize) ConnectionError!void {
        const half = self.write_buf.len / 2;
        var w = Writer.init(self.write_buf[0..half]);
        try encode(&w, header, self.write_buf[half .. half + body_len]);
        try self.sendRaw(w.written());
    }

    /// Read whatever is available into the buffer. Returns false at end of
    /// stream. Blocks only when nothing is buffered by the kernel; callers
    /// poll first.
    pub fn fill(self: *Connection) ConnectionError!bool {
        self.compact();
        if (self.read_len == self.read_buf.len) return error.Malformed;
        const rc = linux.read(self.fd, self.read_buf[self.read_len..].ptr, self.read_buf.len - self.read_len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return true,
            else => return error.ReadFailed,
        }
        if (rc == 0) return false;
        self.read_len += rc;
        return true;
    }

    fn compact(self: *Connection) void {
        if (self.pending_consume == 0) return;
        const rest = self.read_len - self.pending_consume;
        std.mem.copyForwards(u8, self.read_buf[0..rest], self.read_buf[self.pending_consume..self.read_len]);
        self.read_len = rest;
        self.pending_consume = 0;
    }

    /// The next complete buffered message, or null. The message borrows the
    /// read buffer until the next `next` or `fill`.
    pub fn next(self: *Connection) ConnectionError!?Message {
        self.compact();
        const total = (try frameLength(self.read_buf[0..self.read_len])) orelse return null;
        if (total > self.read_buf.len) return error.Malformed;
        if (total > self.read_len) return null;
        self.pending_consume = total;
        return try parse(self.read_buf[0..total]);
    }

    /// Wait up to `timeout_ms` for the connection to become readable.
    pub fn waitReadable(self: *Connection, timeout_ms: i32) ConnectionError!bool {
        var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&fds, 1, timeout_ms);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc != 0,
            .INTR => return false,
            else => return error.ReadFailed,
        }
    }

    /// Send a method call and wait for its reply, discarding unrelated
    /// messages. The returned reply borrows the read buffer until the next
    /// read. An error reply is `error.CallFailed`.
    pub fn call(
        self: *Connection,
        header: Header,
        body: []const u8,
        timeout_ms: i32,
        deadline_clock: std.Io,
    ) ConnectionError!Message {
        var h = header;
        h.type = .method_call;
        h.serial = self.nextSerial();
        try self.send(h, body);
        const deadline = nowMs(deadline_clock) + timeout_ms;
        while (true) {
            while (try self.next()) |message| {
                if (message.reply_serial) |serial| if (serial == h.serial) {
                    if (message.type == .@"error") return error.CallFailed;
                    if (message.type == .method_return) return message;
                };
            }
            const left = deadline - nowMs(deadline_clock);
            if (left <= 0) return error.TimedOut;
            if (!try self.waitReadable(@intCast(@min(left, std.math.maxInt(i32))))) continue;
            if (!try self.fill()) return error.Disconnected;
        }
    }

    /// Say `Hello` to the bus and record the unique name it assigns.
    pub fn hello(self: *Connection, timeout_ms: i32, io: std.Io) ConnectionError!void {
        const reply = try self.call(.{
            .type = .method_call,
            .serial = 0,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
            .destination = "org.freedesktop.DBus",
        }, "", timeout_ms, io);
        if (!std.mem.eql(u8, reply.signature, "s")) return error.Malformed;
        var r = reply.bodyReader();
        const name = try r.string();
        if (name.len > self.unique_name_buf.len) return error.Malformed;
        @memcpy(self.unique_name_buf[0..name.len], name);
        self.unique_name_len = name.len;
    }
};

/// Milliseconds on the monotonic clock.
pub fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

/// Blocking byte transport over a socket, used for the SASL handshake and
/// for writes. Writes never raise SIGPIPE.
const FdTransport = struct {
    fd: i32,

    pub fn writeAll(self: *FdTransport, bytes: []const u8) error{WriteFailed}!void {
        var sent: usize = 0;
        while (sent < bytes.len) {
            const rc = linux.sendto(self.fd, bytes[sent..].ptr, bytes.len - sent, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => sent += rc,
                .INTR => {},
                else => return error.WriteFailed,
            }
        }
    }

    pub fn readByte(self: *FdTransport) error{ReadFailed}!?u8 {
        var b: [1]u8 = undefined;
        while (true) {
            const rc = linux.read(self.fd, &b, 1);
            switch (linux.errno(rc)) {
                .SUCCESS => return if (rc == 0) null else b[0],
                .INTR => {},
                else => return error.ReadFailed,
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "basic types round-trip with alignment" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try w.byte(7);
    try w.uint32(0xdeadbeef);
    try w.byte(1);
    try w.int16(-2);
    try w.uint64(0x0102030405060708);
    try w.boolean(true);
    try w.double(1.5);
    try w.int32(-5);
    try w.string("héllo");
    try w.objectPath("/org/a11y/atspi/accessible/root");
    try w.signature("a(so)");
    // Padding: the u32 after one byte starts at offset 4.
    try testing.expectEqual(@as(u8, 0xef), w.written()[4]);
    try testing.expectEqual(@as(u8, 0), w.written()[1]);

    var r = Reader.init(w.written(), .little);
    try testing.expectEqual(@as(u8, 7), try r.byte());
    try testing.expectEqual(@as(u32, 0xdeadbeef), try r.uint32());
    try testing.expectEqual(@as(u8, 1), try r.byte());
    try testing.expectEqual(@as(i16, -2), try r.int16());
    try testing.expectEqual(@as(u64, 0x0102030405060708), try r.uint64());
    try testing.expect(try r.boolean());
    try testing.expectEqual(@as(f64, 1.5), try r.double());
    try testing.expectEqual(@as(i32, -5), try r.int32());
    try testing.expectEqualStrings("héllo", try r.string());
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/root", try r.objectPath());
    try testing.expectEqualStrings("a(so)", try r.signature());
    try testing.expectEqual(w.len, r.pos);
}

test "big-endian values decode" {
    const bytes = [_]u8{ 0, 0, 0, 5, 0, 0, 0, 2, 'h', 'i', 0 };
    var r = Reader.init(&bytes, .big);
    try testing.expectEqual(@as(u32, 5), try r.uint32());
    try testing.expectEqualStrings("hi", try r.string());
}

test "nested arrays of structs, variants and dict entries round-trip" {
    var buf: [512]u8 = undefined;
    var w = Writer.init(&buf);
    try w.byte(9); // misalign the array start
    const outer = try w.beginArray(8);
    for ([_][]const u8{ "/a", "/b/c" }) |path| {
        try w.reference(":1.5", path);
    }
    try w.endArray(outer);
    // a{sv} with an int and a nested a(ii).
    const dict = try w.beginArray(8);
    try w.beginStruct();
    try w.string("n");
    try w.beginVariant("i");
    try w.int32(42);
    try w.beginStruct();
    try w.string("pairs");
    try w.beginVariant("a(ii)");
    const inner = try w.beginArray(8);
    try w.beginStruct();
    try w.int32(1);
    try w.int32(2);
    try w.endArray(inner);
    try w.endArray(dict);
    // An empty array of 8-aligned elements still pads to the element.
    const empty = try w.beginArray(8);
    try w.endArray(empty);

    var r = Reader.init(w.written(), .little);
    _ = try r.byte();
    const end = try r.beginArray(8);
    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    while (r.pos < end) : (count += 1) {
        try r.beginStruct();
        try testing.expectEqualStrings(":1.5", try r.string());
        paths[count] = try r.objectPath();
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("/b/c", paths[1]);
    // Skip the whole dict generically, then the empty array.
    try r.skip("a{sv}");
    try r.skip("a(so)");
    try testing.expectEqual(w.len, r.pos);
}

test "invalid strings, paths and signatures are refused" {
    var buf: [64]u8 = undefined;
    var w = Writer.init(&buf);
    try testing.expectError(error.InvalidString, w.string("a\x00b"));
    try testing.expectError(error.InvalidString, w.string("\xff"));
    try testing.expectError(error.InvalidString, w.objectPath("no/slash"));
    try testing.expectError(error.InvalidString, w.objectPath("/trailing/"));
    try testing.expectError(error.InvalidString, w.objectPath("/a//b"));
    try testing.expectError(error.InvalidString, w.objectPath("/a-b"));
    try testing.expectError(error.InvalidString, w.signature("a"));
    try testing.expectError(error.InvalidString, w.signature("(si"));
    try testing.expectError(error.InvalidString, w.signature("a{vs}"));
    try testing.expectError(error.InvalidString, w.beginVariant("ss"));
    try testing.expect(validSignature("a((so)(so)(so)iiassusau)"));
    try testing.expect(validSignature("siiva{sv}"));
    var small: [3]u8 = undefined;
    var tiny = Writer.init(&small);
    try testing.expectError(error.MessageTooLarge, tiny.uint32(1));
}

test "truncated and hostile input is malformed, never a crash" {
    var r = Reader.init(&[_]u8{ 0xff, 0xff, 0xff, 0x7f }, .little);
    try testing.expectError(error.Malformed, r.string());
    var nonzero_pad = Reader.init(&[_]u8{ 1, 1, 0, 0, 5, 0, 0, 0 }, .little);
    _ = try nonzero_pad.byte();
    try testing.expectError(error.Malformed, nonzero_pad.uint32());
    var bad_bool = Reader.init(&[_]u8{ 2, 0, 0, 0 }, .little);
    try testing.expectError(error.Malformed, bad_bool.boolean());
    // A variant nested beyond max_depth.
    var deep: [8 * 80]u8 = undefined;
    var w = Writer.init(&deep);
    for (0..70) |_| try w.signature("v");
    try w.signature("i");
    var dr = Reader.init(w.written(), .little);
    try testing.expectError(error.Malformed, dr.skip("v"));
}

test "messages encode and parse with every header field" {
    var body_buf: [64]u8 = undefined;
    var body = Writer.init(&body_buf);
    try body.reference(":1.2", "/org/a11y/atspi/accessible/root");
    var buf: [512]u8 = undefined;
    var w = Writer.init(&buf);
    try encode(&w, .{
        .type = .method_call,
        .serial = 3,
        .path = "/org/a11y/atspi/accessible/root",
        .interface = "org.a11y.atspi.Socket",
        .member = "Embed",
        .destination = "org.a11y.atspi.Registry",
        .signature = "(so)",
    }, body.written());
    try testing.expectEqual(@as(?usize, w.len), try frameLength(w.written()));
    const m = try parse(w.written());
    try testing.expectEqual(MessageType.method_call, m.type);
    try testing.expectEqual(@as(u32, 3), m.serial);
    try testing.expectEqualStrings("Embed", m.member.?);
    try testing.expectEqualStrings("org.a11y.atspi.Registry", m.destination.?);
    try testing.expectEqualStrings("(so)", m.signature);
    try testing.expect(m.isCall("org.a11y.atspi.Socket", "Embed"));
    try testing.expect(m.wantsReply());
    var r = m.bodyReader();
    try r.beginStruct();
    try testing.expectEqualStrings(":1.2", try r.string());

    var reply_buf: [128]u8 = undefined;
    var rw = Writer.init(&reply_buf);
    try encode(&rw, .{ .type = .@"error", .serial = 9, .reply_serial = 3, .error_name = "org.x.Err" }, "");
    const reply = try parse(rw.written());
    try testing.expectEqual(@as(?u32, 3), reply.reply_serial);
    try testing.expectEqualStrings("org.x.Err", reply.error_name.?);
}

test "message parsing refuses broken headers" {
    var buf: [256]u8 = undefined;
    var w = Writer.init(&buf);
    try encode(&w, .{ .type = .signal, .serial = 1, .path = "/a", .interface = "a.b", .member = "C" }, "");
    var copy: [256]u8 = undefined;
    const good = w.written();
    @memcpy(copy[0..good.len], good);
    // Serial zero.
    copy[8] = 0;
    try testing.expectError(error.Malformed, parse(copy[0..good.len]));
    @memcpy(copy[0..good.len], good);
    // Wrong protocol version.
    copy[3] = 2;
    try testing.expectError(error.Malformed, frameLength(copy[0..good.len]));
    @memcpy(copy[0..good.len], good);
    // Truncated.
    try testing.expectError(error.Malformed, parse(copy[0 .. good.len - 1]));
    try testing.expectEqual(@as(?usize, null), try frameLength(copy[0..8]));
    // A signal without a member.
    var w2 = Writer.init(&buf);
    try encode(&w2, .{ .type = .signal, .serial = 1, .path = "/a", .interface = "a.b" }, "");
    try testing.expectError(error.Malformed, parse(w2.written()));
    // An oversized body length.
    var huge = [_]u8{ 'l', 4, 0, 1, 0xff, 0xff, 0xff, 0x7f, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.Malformed, frameLength(&huge));
}

test "addresses parse path, abstract and escapes" {
    const a = try parseAddress("unix:path=/run/user/1000/bus");
    try testing.expectEqualStrings("/run/user/1000/bus", a.name());
    try testing.expect(!a.abstract);
    const b = try parseAddress("tcp:host=x;unix:abstract=/tmp/dbus-AbC,guid=123");
    try testing.expectEqualStrings("/tmp/dbus-AbC", b.name());
    try testing.expect(b.abstract);
    const c = try parseAddress("unix:guid=1,path=/tmp/a%20b");
    try testing.expectEqualStrings("/tmp/a b", c.name());
    try testing.expectError(error.UnsupportedAddress, parseAddress("tcp:host=localhost,port=1"));
    try testing.expectError(error.UnsupportedAddress, parseAddress("unix:path=/x%2"));
    try testing.expectError(error.UnsupportedAddress, parseAddress("unix:path=/x%00"));
    var long: [300]u8 = undefined;
    @memcpy(long[0..10], "unix:path=");
    @memset(long[10..], 'a');
    try testing.expectError(error.UnsupportedAddress, parseAddress(&long));
}

const ScriptedTransport = struct {
    input: []const u8,
    read_pos: usize = 0,
    output: [256]u8 = undefined,
    output_len: usize = 0,

    pub fn writeAll(self: *ScriptedTransport, bytes: []const u8) error{WriteFailed}!void {
        if (bytes.len > self.output.len - self.output_len) return error.WriteFailed;
        @memcpy(self.output[self.output_len..][0..bytes.len], bytes);
        self.output_len += bytes.len;
    }

    pub fn readByte(self: *ScriptedTransport) error{ReadFailed}!?u8 {
        if (self.read_pos == self.input.len) return null;
        self.read_pos += 1;
        return self.input[self.read_pos - 1];
    }
};

test "SASL EXTERNAL sends the hex uid and BEGIN, and leaves later bytes unread" {
    var t: ScriptedTransport = .{ .input = "OK 1234deadbeef\r\nl\x02" };
    try authenticate(&t, 1000);
    try testing.expectEqualStrings("\x00AUTH EXTERNAL 31303030\r\nBEGIN\r\n", t.output[0..t.output_len]);
    try testing.expectEqual(@as(usize, 17), t.read_pos);

    var rejected: ScriptedTransport = .{ .input = "REJECTED EXTERNAL\r\n" };
    try testing.expectError(error.AuthRejected, authenticate(&rejected, 0));
    var garbage: ScriptedTransport = .{ .input = "WAT\r\n" };
    try testing.expectError(error.AuthProtocol, authenticate(&garbage, 0));
    var eof: ScriptedTransport = .{ .input = "OK" };
    try testing.expectError(error.AuthProtocol, authenticate(&eof, 0));
    const endless = "x" ** 600;
    var long: ScriptedTransport = .{ .input = endless };
    try testing.expectError(error.AuthProtocol, authenticate(&long, 0));
}
