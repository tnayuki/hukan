//! The X11 protocol as far as the agent speaks it: the requests it sends, encoded byte for byte,
//! and the replies it reads, taken apart. No system calls here, so it is tested on any machine;
//! x11.zig is what puts these on a socket.
//!
//! Everything is little-endian: the connection is opened saying so, and the server answers in kind.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const atom_none: u32 = 0;
pub const atom_string: u32 = 31;
pub const atom_window: u32 = 33;

/// Event types XTEST fakes.
pub const key_press: u8 = 2;
pub const key_release: u8 = 3;
pub const button_press: u8 = 4;
pub const button_release: u8 = 5;
pub const motion_notify: u8 = 6;

/// What a display name says: the display's number and the screen on it. Only local displays —
/// `:0`, `unix:0`, `:1.0` — since the agent is never pointed at a remote one.
pub const DisplayName = struct { number: u32, screen: u32 };

pub fn parseDisplay(name: []const u8) ?DisplayName {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return null;
    const host = name[0..colon];
    if (host.len != 0 and !std.mem.eql(u8, host, "unix")) return null;
    const rest = name[colon + 1 ..];
    var number_text = rest;
    var screen: u32 = 0;
    if (std.mem.lastIndexOfScalar(u8, rest, '.')) |dot| {
        number_text = rest[0..dot];
        screen = std.fmt.parseInt(u32, rest[dot + 1 ..], 10) catch return null;
    }
    const number = std.fmt.parseInt(u32, number_text, 10) catch return null;
    return .{ .number = number, .screen = screen };
}

/// The MIT-MAGIC-COOKIE-1 for a local display out of an Xauthority file, the way libXau
/// chooses it: the first entry for any address or for this host, for this display or for every one.
/// Null when there is none, and the connection is tried without.
pub fn findCookie(file: []const u8, hostname: []const u8, display: []const u8) ?[16]u8 {
    const family_local = 256;
    const family_wild = 65535;
    var at: usize = 0;
    while (at + 2 <= file.len) {
        const family = std.mem.readInt(u16, file[at..][0..2], .big);
        at += 2;
        var fields: [4][]const u8 = undefined;
        for (&fields) |*f| {
            if (at + 2 > file.len) return null;
            const length = std.mem.readInt(u16, file[at..][0..2], .big);
            at += 2;
            if (at + length > file.len) return null;
            f.* = file[at..][0..length];
            at += length;
        }
        const address, const number, const name, const data = fields;
        const address_matches = family == family_wild or (family == family_local and std.mem.eql(u8, address, hostname));
        const display_matches = number.len == 0 or std.mem.eql(u8, number, display);
        if (address_matches and display_matches) {
            if (!std.mem.eql(u8, name, "MIT-MAGIC-COOKIE-1") or data.len != 16) return null;
            return data[0..16].*;
        }
    }
    return null;
}

/// A request being put together: the header's length is filled in when it is finished.
pub const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    arena: Allocator,

    pub fn begin(arena: Allocator, opcode: u8, data: u8) Builder {
        var b: Builder = .{ .arena = arena };
        b.byte(opcode);
        b.byte(data);
        b.u16_(0);
        return b;
    }

    pub fn byte(b: *Builder, value: u8) void {
        b.bytes.append(b.arena, value) catch @panic("out of memory");
    }

    pub fn u16_(b: *Builder, value: u16) void {
        b.bytes.appendSlice(b.arena, &std.mem.toBytes(std.mem.nativeToLittle(u16, value))) catch @panic("out of memory");
    }

    pub fn i16_(b: *Builder, value: i16) void {
        b.u16_(@bitCast(value));
    }

    pub fn u32_(b: *Builder, value: u32) void {
        b.bytes.appendSlice(b.arena, &std.mem.toBytes(std.mem.nativeToLittle(u32, value))) catch @panic("out of memory");
    }

    pub fn pad(b: *Builder, count: usize) void {
        b.bytes.appendNTimes(b.arena, 0, count) catch @panic("out of memory");
    }

    pub fn string(b: *Builder, text: []const u8) void {
        b.bytes.appendSlice(b.arena, text) catch @panic("out of memory");
        b.pad(padding(text.len));
    }

    pub fn finish(b: *Builder) []const u8 {
        b.pad(padding(b.bytes.items.len));
        std.mem.writeInt(u16, b.bytes.items[2..4], @intCast(b.bytes.items.len / 4), .little);
        return b.bytes.items;
    }
};

pub fn padding(length: usize) usize {
    return (4 - length % 4) % 4;
}

/// The connection setup: little-endian, protocol 11.0, and the cookie when there is one.
pub fn setup(arena: Allocator, cookie: ?[16]u8) []const u8 {
    var b: Builder = .{ .arena = arena };
    b.byte('l');
    b.byte(0);
    b.u16_(11);
    b.u16_(0);
    const name = if (cookie != null) "MIT-MAGIC-COOKIE-1" else "";
    b.u16_(@intCast(name.len));
    b.u16_(if (cookie != null) 16 else 0);
    b.u16_(0);
    b.string(name);
    if (cookie) |c| b.string(&c);
    return b.bytes.items;
}

pub const Setup = struct {
    root: u32,
    width: u16,
    height: u16,
    min_keycode: u8,
    max_keycode: u8,
};

pub const SetupError = error{ Refused, Malformed, NoSuchScreen };

/// Reads what a successful setup reply says, for the screen asked for. `reply` is the whole reply,
/// its eight-byte head included.
pub fn parseSetup(reply: []const u8, screen: u32) SetupError!Setup {
    if (reply.len < 8) return error.Malformed;
    if (reply[0] != 1) return error.Refused;
    if (reply.len < 40) return error.Malformed;
    const vendor_length = read(u16, reply, 24);
    const screens = reply[28];
    const formats = reply[29];
    const min_keycode = reply[34];
    const max_keycode = reply[35];
    var at: usize = 40 + vendor_length + padding(vendor_length) + @as(usize, formats) * 8;
    var index: u32 = 0;
    while (index < screens) : (index += 1) {
        if (at + 40 > reply.len) return error.Malformed;
        if (index == screen) return .{
            .root = read(u32, reply, at),
            .width = read(u16, reply, at + 20),
            .height = read(u16, reply, at + 22),
            .min_keycode = min_keycode,
            .max_keycode = max_keycode,
        };
        // A screen's allowed depths follow it, each with its visuals.
        const depths = reply[at + 39];
        at += 40;
        var d: u8 = 0;
        while (d < depths) : (d += 1) {
            if (at + 8 > reply.len) return error.Malformed;
            const visuals = read(u16, reply, at + 2);
            at += 8 + @as(usize, visuals) * 24;
        }
    }
    return error.NoSuchScreen;
}

/// Why a setup was refused, as the server put it.
pub fn refusal(reply: []const u8) []const u8 {
    if (reply.len < 8) return "";
    const length = reply[1];
    if (reply.len < 8 + @as(usize, length)) return "";
    return reply[8..][0..length];
}

pub fn read(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

pub fn internAtom(arena: Allocator, name: []const u8, only_if_exists: bool) []const u8 {
    var b: Builder = .begin(arena, 16, @intFromBool(only_if_exists));
    b.u16_(@intCast(name.len));
    b.pad(2);
    b.string(name);
    return b.finish();
}

pub fn getProperty(arena: Allocator, window: u32, property: u32, kind: u32, longs: u32) []const u8 {
    var b: Builder = .begin(arena, 20, 0);
    b.u32_(window);
    b.u32_(property);
    b.u32_(kind);
    b.u32_(0);
    b.u32_(longs);
    return b.finish();
}

/// The value of a GetProperty reply: its length counted in units of its format.
pub fn propertyValue(reply: []const u8) []const u8 {
    if (reply.len < 32) return &.{};
    const format = reply[1];
    const count = read(u32, reply, 16);
    const length = @as(usize, count) * (format / 8);
    if (32 + length > reply.len) return &.{};
    return reply[32..][0..length];
}

pub fn getGeometry(arena: Allocator, drawable: u32) []const u8 {
    var b: Builder = .begin(arena, 14, 0);
    b.u32_(drawable);
    return b.finish();
}

pub fn translateCoordinates(arena: Allocator, from: u32, to: u32, x: i16, y: i16) []const u8 {
    var b: Builder = .begin(arena, 40, 0);
    b.u32_(from);
    b.u32_(to);
    b.i16_(x);
    b.i16_(y);
    return b.finish();
}

pub fn getImage(arena: Allocator, drawable: u32, x: i16, y: i16, width: u16, height: u16) []const u8 {
    const z_pixmap = 2;
    var b: Builder = .begin(arena, 73, z_pixmap);
    b.u32_(drawable);
    b.i16_(x);
    b.i16_(y);
    b.u16_(width);
    b.u16_(height);
    b.u32_(0xffffffff);
    return b.finish();
}

pub fn getKeyboardMapping(arena: Allocator, first: u8, count: u8) []const u8 {
    var b: Builder = .begin(arena, 101, 0);
    b.byte(first);
    b.byte(count);
    b.pad(2);
    return b.finish();
}

pub fn changeKeyboardMapping(arena: Allocator, first: u8, keysyms: []const u32) []const u8 {
    var b: Builder = .begin(arena, 100, 1);
    b.byte(first);
    b.byte(@intCast(keysyms.len));
    b.pad(2);
    for (keysyms) |k| b.u32_(k);
    return b.finish();
}

pub fn getInputFocus(arena: Allocator) []const u8 {
    var b: Builder = .begin(arena, 43, 0);
    return b.finish();
}

pub fn queryExtension(arena: Allocator, name: []const u8) []const u8 {
    var b: Builder = .begin(arena, 98, 0);
    b.u16_(@intCast(name.len));
    b.pad(2);
    b.string(name);
    return b.finish();
}

/// XTEST's FakeInput, which is minor request 2 of the extension.
pub fn fakeInput(arena: Allocator, xtest: u8, kind: u8, detail: u8, root: u32, x: i16, y: i16) []const u8 {
    var b: Builder = .begin(arena, xtest, 2);
    b.byte(kind);
    b.byte(detail);
    b.pad(2);
    b.u32_(0); // time: now
    b.u32_(root);
    b.pad(8);
    b.i16_(x);
    b.i16_(y);
    b.pad(7);
    b.byte(0); // device: the core one
    return b.finish();
}

/// The name of an X error, as the protocol spells it.
pub fn errorName(code: u8) []const u8 {
    const names = [_][]const u8{
        "Success",     "BadRequest",  "BadValue",    "BadWindow",   "BadPixmap", "BadAtom",
        "BadCursor",   "BadFont",     "BadMatch",    "BadDrawable", "BadAccess", "BadAlloc",
        "BadColormap", "BadGContext", "BadIDChoice", "BadName",     "BadLength", "BadImplementation",
    };
    return if (code < names.len) names[code] else "BadExtension";
}

/// A ZPixmap of depth 24 at 32 bits a pixel — blue, green, red, unused — as RGBA.
pub fn bgrxToRgba(bgrx: []const u8, rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        rgba[i] = bgrx[i + 2];
        rgba[i + 1] = bgrx[i + 1];
        rgba[i + 2] = bgrx[i];
        rgba[i + 3] = 0xff;
    }
}

const testing = std.testing;

test "a display name is its number and screen, and only a local one" {
    try testing.expectEqual(DisplayName{ .number = 0, .screen = 0 }, parseDisplay(":0").?);
    try testing.expectEqual(DisplayName{ .number = 1, .screen = 2 }, parseDisplay(":1.2").?);
    try testing.expectEqual(DisplayName{ .number = 10, .screen = 0 }, parseDisplay("unix:10").?);
    try testing.expectEqual(@as(?DisplayName, null), parseDisplay("example.com:0"));
    try testing.expectEqual(@as(?DisplayName, null), parseDisplay("0"));
    try testing.expectEqual(@as(?DisplayName, null), parseDisplay(":"));
}

fn entry(list: *std.ArrayList(u8), family: u16, fields: [4][]const u8) !void {
    var two: [2]u8 = undefined;
    std.mem.writeInt(u16, &two, family, .big);
    try list.appendSlice(testing.allocator, &two);
    for (fields) |f| {
        std.mem.writeInt(u16, &two, @intCast(f.len), .big);
        try list.appendSlice(testing.allocator, &two);
        try list.appendSlice(testing.allocator, f);
    }
}

test "the cookie is the first entry for this host and display, or for any" {
    var file: std.ArrayList(u8) = .empty;
    defer file.deinit(testing.allocator);
    const a = "AAAAAAAAAAAAAAAA";
    const b = "BBBBBBBBBBBBBBBB";
    const c = "CCCCCCCCCCCCCCCC";
    try entry(&file, 256, .{ "otherhost", "0", "MIT-MAGIC-COOKIE-1", a });
    try entry(&file, 256, .{ "guest", "1", "MIT-MAGIC-COOKIE-1", b });
    try entry(&file, 256, .{ "guest", "0", "MIT-MAGIC-COOKIE-1", c });
    try testing.expectEqualSlices(u8, c, &findCookie(file.items, "guest", "0").?);
    try testing.expectEqualSlices(u8, b, &findCookie(file.items, "guest", "1").?);
    try testing.expectEqual(@as(?[16]u8, null), findCookie(file.items, "nobody", "0"));

    var wild: std.ArrayList(u8) = .empty;
    defer wild.deinit(testing.allocator);
    try entry(&wild, 65535, .{ "", "", "MIT-MAGIC-COOKIE-1", a });
    try testing.expectEqualSlices(u8, a, &findCookie(wild.items, "anything", "7").?);
    // A truncated file is no cookie, not a crash.
    try testing.expectEqual(@as(?[16]u8, null), findCookie(file.items[0..20], "guest", "0"));
}

test "requests are encoded as the protocol spells them" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // InternAtom "WM_NAME": opcode, only-if-exists, length 4 units, name length, padding, name.
    try testing.expectEqualSlices(u8, &.{ 16, 1, 4, 0, 7, 0, 0, 0, 'W', 'M', '_', 'N', 'A', 'M', 'E', 0 }, internAtom(a, "WM_NAME", true));
    try testing.expectEqualSlices(u8, &.{ 43, 0, 1, 0 }, getInputFocus(a));
    try testing.expectEqualSlices(u8, &.{ 14, 0, 2, 0, 0x78, 0x56, 0x34, 0x12 }, getGeometry(a, 0x12345678));
    try testing.expectEqualSlices(u8, &.{ 101, 0, 2, 0, 8, 248, 0, 0 }, getKeyboardMapping(a, 8, 248));
    const image = getImage(a, 1, -2, 3, 640, 480);
    try testing.expectEqual(@as(usize, 20), image.len);
    try testing.expectEqual(@as(u8, 2), image[1]);
    try testing.expectEqual(@as(u16, 5), read(u16, image, 2));
    try testing.expectEqual(@as(i16, -2), @as(i16, @bitCast(read(u16, image, 8))));
    try testing.expectEqual(@as(u32, 0xffffffff), read(u32, image, 16));
    // FakeInput is 36 bytes.
    const fake = fakeInput(a, 132, motion_notify, 0, 0x100, 10, 20);
    try testing.expectEqual(@as(usize, 36), fake.len);
    try testing.expectEqual(@as(u8, 132), fake[0]);
    try testing.expectEqual(@as(u8, 2), fake[1]);
    try testing.expectEqual(@as(u16, 9), read(u16, fake, 2));
    try testing.expectEqual(motion_notify, fake[4]);
    try testing.expectEqual(@as(u32, 0x100), read(u32, fake, 12));
    try testing.expectEqual(@as(u16, 10), read(u16, fake, 24));
    try testing.expectEqual(@as(u16, 20), read(u16, fake, 26));
    const change = changeKeyboardMapping(a, 200, &.{ 0x1000041, 0x1000041 });
    try testing.expectEqualSlices(u8, &.{ 100, 1, 4, 0, 200, 2, 0, 0 }, change[0..8]);
    try testing.expectEqual(@as(u32, 0x1000041), read(u32, change, 12));
    // The setup, with a cookie and without.
    const bare = setup(a, null);
    try testing.expectEqualSlices(u8, &.{ 'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, bare);
    const with = setup(a, "0123456789abcdef".*);
    try testing.expectEqual(@as(usize, 12 + 20 + 16), with.len);
    try testing.expectEqual(@as(u16, 18), read(u16, with, 6));
    try testing.expectEqual(@as(u16, 16), read(u16, with, 8));
    try testing.expectEqualSlices(u8, "0123456789abcdef", with[32..48]);
}

test "a setup reply gives the screen asked for" {
    var reply: [8 + 32 + 8 + 8 + 40 + 8 + 24 + 40]u8 = @splat(0);
    reply[0] = 1;
    std.mem.writeInt(u16, reply[24..26], 5, .little); // vendor "hukan", padded to 8
    reply[28] = 2; // screens
    reply[29] = 1; // formats
    reply[34] = 8;
    reply[35] = 255;
    const first = 40 + 8 + 8;
    std.mem.writeInt(u32, reply[first..][0..4], 0x2a, .little);
    std.mem.writeInt(u16, reply[first + 20 ..][0..2], 1920, .little);
    std.mem.writeInt(u16, reply[first + 22 ..][0..2], 1080, .little);
    reply[first + 39] = 1; // one depth, with one visual
    std.mem.writeInt(u16, reply[first + 40 + 2 ..][0..2], 1, .little);
    const second = first + 40 + 8 + 24;
    std.mem.writeInt(u32, reply[second..][0..4], 0x99, .little);
    const one = try parseSetup(&reply, 0);
    try testing.expectEqual(@as(u32, 0x2a), one.root);
    try testing.expectEqual(@as(u16, 1920), one.width);
    try testing.expectEqual(@as(u8, 8), one.min_keycode);
    try testing.expectEqual(@as(u8, 255), one.max_keycode);
    try testing.expectEqual(@as(u32, 0x99), (try parseSetup(&reply, 1)).root);
    try testing.expectError(error.NoSuchScreen, parseSetup(&reply, 2));
    reply[0] = 0;
    try testing.expectError(error.Refused, parseSetup(&reply, 0));
}

test "a property's value is counted in its format" {
    var reply: [32 + 8]u8 = @splat(0);
    reply[0] = 1;
    reply[1] = 32;
    std.mem.writeInt(u32, reply[16..20], 2, .little);
    try testing.expectEqual(@as(usize, 8), propertyValue(&reply).len);
    reply[1] = 8;
    std.mem.writeInt(u32, reply[16..20], 5, .little);
    try testing.expectEqual(@as(usize, 5), propertyValue(&reply).len);
    std.mem.writeInt(u32, reply[16..20], 50, .little);
    try testing.expectEqual(@as(usize, 0), propertyValue(&reply).len);
}

test "a picture goes from blue-first to RGBA" {
    const bgrx = [_]u8{ 1, 2, 3, 0, 10, 20, 30, 0 };
    var rgba: [8]u8 = undefined;
    bgrxToRgba(&bgrx, &rgba);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 30, 20, 10, 255 }, &rgba);
}
