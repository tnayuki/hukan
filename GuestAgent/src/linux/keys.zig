//! Keys as X11 names them, which is also how GNOME Shell takes them: which keysym a key's name
//! stands for. Pure, so it is tested on any machine.

const std = @import("std");

const named = std.StaticStringMap(u32).initComptime(.{
    .{ "return", 0xff0d }, .{ "enter", 0xff0d },         .{ "tab", 0xff09 },    .{ "space", 0x20 },
    .{ "delete", 0xff08 }, .{ "forwarddelete", 0xffff }, .{ "escape", 0xff1b }, .{ "esc", 0xff1b },
    .{ "left", 0xff51 },   .{ "up", 0xff52 },            .{ "right", 0xff53 },  .{ "down", 0xff54 },
    .{ "home", 0xff50 },   .{ "end", 0xff57 },           .{ "pageup", 0xff55 }, .{ "pagedown", 0xff56 },
});

const modifiers = std.StaticStringMap(u32).initComptime(.{
    // Super_L, as the Windows key is on Windows.
    .{ "command", 0xffeb }, .{ "cmd", 0xffeb },    .{ "super", 0xffeb },
    .{ "shift", 0xffe1 },   .{ "option", 0xffe9 }, .{ "alt", 0xffe9 },
    .{ "control", 0xffe3 }, .{ "ctrl", 0xffe3 },
});

/// The keysym a key's name stands for: a named key, F1 to F12, or one letter or digit.
pub fn keysymFor(buffer: []u8, key: []const u8) ?u32 {
    if (key.len > buffer.len) return null;
    const lower = std.ascii.lowerString(buffer[0..key.len], key);
    if (named.get(lower)) |keysym| return keysym;
    if (lower.len >= 2 and lower.len <= 3 and lower[0] == 'f') {
        const function = std.fmt.parseInt(u8, lower[1..], 10) catch 0;
        // "f01" is not a key's name, so the digits have to be the number as it is written.
        if (function >= 1 and function <= 12 and lower[1] != '0') return 0xffbe + @as(u32, function) - 1;
    }
    const view = std.unicode.Utf8View.init(lower) catch return null;
    var it = view.iterator();
    const r = it.nextCodepoint() orelse return null;
    if (it.nextCodepoint() != null) return null;
    // Latin-1 letters and digits are their own keysyms.
    if (isLetterOrDigit(r)) return r;
    return null;
}

/// Letters and digits: ASCII, and the Latin-1 letters past it. What a key's name can be beyond
/// that has no key on any layout an agent is pointed at.
fn isLetterOrDigit(r: u21) bool {
    return switch (r) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        0xc0...0xd6, 0xd8...0xf6, 0xf8...0xff => true,
        else => false,
    };
}

pub fn modifierKeysym(buffer: []u8, name: []const u8) ?u32 {
    if (name.len > buffer.len) return null;
    return modifiers.get(std.ascii.lowerString(buffer[0..name.len], name));
}

const testing = std.testing;

test "a key's name" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqual(@as(?u32, 0xff0d), keysymFor(&buffer, "Return"));
    try testing.expectEqual(@as(?u32, 0xffbe), keysymFor(&buffer, "F1"));
    try testing.expectEqual(@as(?u32, 0xffc9), keysymFor(&buffer, "f12"));
    try testing.expectEqual(@as(?u32, null), keysymFor(&buffer, "f13"));
    try testing.expectEqual(@as(?u32, null), keysymFor(&buffer, "f01"));
    try testing.expectEqual(@as(?u32, 'a'), keysymFor(&buffer, "A"));
    try testing.expectEqual(@as(?u32, '7'), keysymFor(&buffer, "7"));
    try testing.expectEqual(@as(?u32, null), keysymFor(&buffer, "-"));
    try testing.expectEqual(@as(?u32, null), keysymFor(&buffer, "ab"));
    try testing.expectEqual(@as(?u32, null), keysymFor(&buffer, ""));
    try testing.expectEqual(@as(?u32, 0xffe3), modifierKeysym(&buffer, "Ctrl"));
    try testing.expectEqual(@as(?u32, null), modifierKeysym(&buffer, "hyper"));
}
