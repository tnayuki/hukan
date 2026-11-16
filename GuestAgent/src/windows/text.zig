//! The parts of the Windows agent that are only text — names, ids, the shortening of a title — kept
//! apart from the system calls so they run under `zig test` on the Mac the agent is built on.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A line of text cut to 120 characters, its line breaks made spaces: what a window's title or an
/// element's name is shown as on one line of a listing.
pub fn clip(arena: Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + length, text.len);
        if (count == 120) {
            out.appendSlice(arena, "…") catch return text;
            break;
        }
        const piece = text[i..end];
        if (std.mem.eql(u8, piece, "\n") or std.mem.eql(u8, piece, "\r")) {
            out.append(arena, ' ') catch return text;
        } else {
            out.appendSlice(arena, piece) catch return text;
        }
        count += 1;
        i = end;
    }
    return out.items;
}

/// UTF-16 from Windows as UTF-8, with an unpaired surrogate — which a title may well hold, and
/// which JSON cannot carry — read as U+FFFD.
pub fn fromWide(arena: Allocator, wide: []const u16) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < wide.len) : (i += 1) {
        var code: u21 = wide[i];
        if (code >= 0xD800 and code <= 0xDBFF and i + 1 < wide.len and wide[i + 1] >= 0xDC00 and wide[i + 1] <= 0xDFFF) {
            code = 0x10000 + ((code - 0xD800) << 10) + (wide[i + 1] - 0xDC00);
            i += 1;
        } else if (code >= 0xD800 and code <= 0xDFFF) {
            code = 0xFFFD;
        }
        var buffer: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(code, &buffer) catch continue;
        out.appendSlice(arena, buffer[0..n]) catch return "";
    }
    return out.items;
}

/// The virtual key a key's name stands for, where it names one regardless of the layout: the named
/// keys, a letter or a digit, F1 to F12. A symbol is the layout's, and is asked of it instead.
pub fn keyCode(name: []const u8) ?u16 {
    var lower_buffer: [16]u8 = undefined;
    if (name.len > lower_buffer.len) return null;
    const lower = std.ascii.lowerString(&lower_buffer, name);
    const named = [_]struct { []const u8, u16 }{
        .{ "return", 0x0D },   .{ "tab", 0x09 },  .{ "space", 0x20 }, .{ "delete", 0x08 },
        .{ "escape", 0x1B },   .{ "left", 0x25 }, .{ "up", 0x26 },    .{ "right", 0x27 },
        .{ "down", 0x28 },     .{ "home", 0x24 }, .{ "end", 0x23 },   .{ "pageup", 0x21 },
        .{ "pagedown", 0x22 },
    };
    for (named) |entry| if (std.mem.eql(u8, lower, entry[0])) return entry[1];
    if (lower.len == 1 and std.ascii.isAlphanumeric(lower[0])) return std.ascii.toUpper(lower[0]);
    if (lower.len >= 2 and lower[0] == 'f') {
        const f = std.fmt.parseInt(u8, lower[1..], 10) catch return null;
        if (f >= 1 and f <= 12) return 0x6F + @as(u16, f);
    }
    return null;
}

/// The virtual key a modifier's name stands for.
pub fn modifierCode(name: []const u8) ?u16 {
    var lower_buffer: [16]u8 = undefined;
    if (name.len > lower_buffer.len) return null;
    const lower = std.ascii.lowerString(&lower_buffer, name);
    const modifiers = [_]struct { []const u8, u16 }{
        .{ "command", 0x5B }, .{ "cmd", 0x5B }, .{ "windows", 0x5B }, .{ "shift", 0x10 },
        .{ "option", 0x12 },  .{ "alt", 0x12 }, .{ "control", 0x11 }, .{ "ctrl", 0x11 },
    };
    for (modifiers) |entry| if (std.mem.eql(u8, lower, entry[0])) return entry[1];
    return null;
}

/// An element's id — its window and the child positions down to it, `"<hwnd>/0.3.1"`, as in the
/// macOS agent — read back; null when it is not one.
pub const ElementId = struct {
    window: u64,
    path: []const usize,
};

pub fn parseElementId(arena: Allocator, id: []const u8) ?ElementId {
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const window = std.fmt.parseInt(u64, id[0..slash], 10) catch return null;
    var path: std.ArrayList(usize) = .empty;
    var parts = std.mem.splitScalar(u8, id[slash + 1 ..], '.');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const index = std.fmt.parseInt(usize, part, 10) catch return null;
        path.append(arena, index) catch return null;
    }
    return .{ .window = window, .path = path.items };
}

/// The id of an element's child at `index`: a window's own children hang straight off its slash.
pub fn childId(arena: Allocator, id: []const u8, index: usize) []const u8 {
    const separator: []const u8 = if (std.mem.endsWith(u8, id, "/")) "" else ".";
    return std.fmt.allocPrint(arena, "{s}{s}{d}", .{ id, separator, index }) catch id;
}

/// UI Automation's name for a control type id, the way the managed client spelled it.
pub fn controlTypeName(arena: Allocator, id: i32) []const u8 {
    const names = [_][]const u8{
        "Button",     "Calendar", "CheckBox", "ComboBox",    "Edit",         "Hyperlink",   "Image",
        "ListItem",   "List",     "Menu",     "MenuBar",     "MenuItem",     "ProgressBar", "RadioButton",
        "ScrollBar",  "Slider",   "Spinner",  "StatusBar",   "Tab",          "TabItem",     "Text",
        "ToolBar",    "ToolTip",  "Tree",     "TreeItem",    "Custom",       "Group",       "Thumb",
        "DataGrid",   "DataItem", "Document", "SplitButton", "Window",       "Pane",        "Header",
        "HeaderItem", "Table",    "TitleBar", "Separator",   "SemanticZoom", "AppBar",
    };
    const index = @as(i64, id) - 50000;
    if (index >= 0 and index < names.len) return names[@intCast(index)];
    return std.fmt.allocPrint(arena, "{d}", .{id}) catch "?";
}

test "clip cuts at 120 characters, not bytes, and flattens line breaks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a b c", clip(a, "a\nb\rc"));
    const long = try repeat(a, "あ", 130);
    const exactly = try repeat(a, "あ", 120);
    try std.testing.expectEqualStrings(try std.mem.concat(a, u8, &.{ exactly, "…" }), clip(a, long));
    try std.testing.expectEqualStrings(exactly, clip(a, exactly));
}

fn repeat(a: Allocator, piece: []const u8, times: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..times) |_| try out.appendSlice(a, piece);
    return out.items;
}

test "a title's unpaired surrogate is read as U+FFFD" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("A😀B", fromWide(a, &.{ 'A', 0xD83D, 0xDE00, 'B' }));
    try std.testing.expectEqualStrings("A\u{FFFD}B", fromWide(a, &.{ 'A', 0xD83D, 'B' }));
    try std.testing.expectEqualStrings("\u{FFFD}", fromWide(a, &.{0xDE00}));
}

test "key names reach the virtual keys they always have" {
    try std.testing.expectEqual(@as(?u16, 0x0D), keyCode("Return"));
    try std.testing.expectEqual(@as(?u16, 0x08), keyCode("delete"));
    try std.testing.expectEqual(@as(?u16, 'A'), keyCode("a"));
    try std.testing.expectEqual(@as(?u16, '7'), keyCode("7"));
    try std.testing.expectEqual(@as(?u16, 0x70), keyCode("F1"));
    try std.testing.expectEqual(@as(?u16, 0x7B), keyCode("f12"));
    try std.testing.expectEqual(@as(?u16, null), keyCode("f13"));
    try std.testing.expectEqual(@as(?u16, 'F'), keyCode("f")); // the letter, not a function key
    try std.testing.expectEqual(@as(?u16, null), keyCode(";"));
    try std.testing.expectEqual(@as(?u16, null), keyCode("nope"));
    try std.testing.expectEqual(@as(?u16, 0x5B), modifierCode("Command"));
    try std.testing.expectEqual(@as(?u16, 0x11), modifierCode("ctrl"));
    try std.testing.expectEqual(@as(?u16, null), modifierCode("hyper"));
}

test "element ids read back as a window and a path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id = parseElementId(a, "1234/0.3.1").?;
    try std.testing.expectEqual(@as(u64, 1234), id.window);
    try std.testing.expectEqualSlices(usize, &.{ 0, 3, 1 }, id.path);
    try std.testing.expectEqual(@as(usize, 0), parseElementId(a, "1234/").?.path.len);
    try std.testing.expectEqual(@as(?ElementId, null), parseElementId(a, "1234"));
    try std.testing.expectEqual(@as(?ElementId, null), parseElementId(a, "x/0"));
    try std.testing.expectEqual(@as(?ElementId, null), parseElementId(a, "1/0.x"));
    try std.testing.expectEqualStrings("1234/0", childId(a, "1234/", 0));
    try std.testing.expectEqualStrings("1234/0.5", childId(a, "1234/0", 5));
}

test "control types are named as the managed client named them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("Button", controlTypeName(a, 50000));
    try std.testing.expectEqualStrings("Window", controlTypeName(a, 50032));
    try std.testing.expectEqualStrings("AppBar", controlTypeName(a, 50040));
    try std.testing.expectEqualStrings("50041", controlTypeName(a, 50041));
}
