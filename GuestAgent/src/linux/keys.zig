//! Keys as X11 names them: which keysym a character or a key name is, and which keycode of the
//! server's keyboard types it. Pure, so it is tested on any machine.

const std = @import("std");

pub const shift_l: u32 = 0xffe1;

/// The keysym that types a character: Latin-1 as itself, anything else as the Unicode keysym.
pub fn runeKeysym(r: u21) u32 {
    return switch (r) {
        '\n' => 0xff0d,
        '\t' => 0xff09,
        0x20...0x7e, 0xa0...0xff => r,
        else => 0x01000000 + @as(u32, r),
    };
}

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
    if (isLetterOrDigit(r)) return runeKeysym(r);
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

/// The server's keyboard as it maps it now: keysyms per keycode, from `min`.
pub const Keyboard = struct {
    min: u8,
    per: usize,
    keysyms: []const u32,

    pub const Found = struct { code: u8, shifted: bool };

    /// A key that types `keysym` now, and whether it needs Shift.
    pub fn keycode(k: Keyboard, keysym: u32) ?Found {
        if (k.per == 0) return null;
        var i: usize = 0;
        while (i + k.per <= k.keysyms.len) : (i += k.per) {
            const code: u8 = @intCast(@as(usize, k.min) + i / k.per);
            if (k.keysyms[i] == keysym) return .{ .code = code, .shifted = false };
            if (k.per > 1 and k.keysyms[i + 1] == keysym) return .{ .code = code, .shifted = true };
        }
        return null;
    }

    /// A keycode nothing is mapped to, for a character no key types: it is given that character
    /// for the one stroke, the way xdotool types what the layout has no key for.
    pub fn spare(k: Keyboard) ?u8 {
        var one: [1]u8 = undefined;
        const found = k.spares(&one);
        return if (found.len == 1) found[0] else null;
    }

    /// Every keycode nothing is mapped to, the highest first, as many as `out` holds.
    pub fn spares(k: Keyboard, out: []u8) []u8 {
        if (k.per == 0 or k.keysyms.len < k.per) return out[0..0];
        var count: usize = 0;
        var i = (k.keysyms.len / k.per - 1) * k.per;
        while (count < out.len) : (i -= k.per) {
            const empty = for (k.keysyms[i..][0..k.per]) |s| {
                if (s != 0) break false;
            } else true;
            if (empty) {
                out[count] = @intCast(@as(usize, k.min) + i / k.per);
                count += 1;
            }
            if (i == 0) break;
        }
        return out[0..count];
    }
};

const testing = std.testing;

test "a character's keysym" {
    try testing.expectEqual(@as(u32, 'a'), runeKeysym('a'));
    try testing.expectEqual(@as(u32, 0xe9), runeKeysym(0xe9));
    try testing.expectEqual(@as(u32, 0xff0d), runeKeysym('\n'));
    try testing.expectEqual(@as(u32, 0x01003042), runeKeysym(0x3042)); // あ
}

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

test "a key is found in either column, and a spare is the last empty keycode" {
    // Keycodes 8 to 11, two keysyms each.
    const keysyms = [_]u32{ 'a', 'A', '1', '!', 0, 0, 0xffe1, 0 };
    const k: Keyboard = .{ .min = 8, .per = 2, .keysyms = &keysyms };
    try testing.expectEqual(Keyboard.Found{ .code = 8, .shifted = false }, k.keycode('a').?);
    try testing.expectEqual(Keyboard.Found{ .code = 9, .shifted = true }, k.keycode('!').?);
    try testing.expectEqual(@as(?Keyboard.Found, null), k.keycode('z'));
    try testing.expectEqual(@as(?u8, 10), k.spare());
    const full = [_]u32{ 'a', 'A' };
    try testing.expectEqual(@as(?u8, null), (Keyboard{ .min = 8, .per = 2, .keysyms = &full }).spare());
}

test "every spare is listed, the highest first, as many as there is room for" {
    // Keycodes 8 to 13: 9, 11 and 13 are empty.
    const keysyms = [_]u32{ 'a', 'A', 0, 0, '1', '!', 0, 0, 0xffe1, 0, 0, 0 };
    const k: Keyboard = .{ .min = 8, .per = 2, .keysyms = &keysyms };
    var out: [8]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 13, 11, 9 }, k.spares(&out));
    var two: [2]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{ 13, 11 }, k.spares(&two));
    const none = [_]u32{ 'a', 'A' };
    try testing.expectEqual(@as(usize, 0), (Keyboard{ .min = 8, .per = 2, .keysyms = &none }).spares(&out).len);
}
