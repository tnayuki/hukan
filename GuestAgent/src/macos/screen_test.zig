//! The macOS screen, run here. Every request changes nothing on the machine running it: each only
//! reads, or is refused before anything is posted or configured. Built with screen.m compiled by
//! Xcode's clang and the frameworks, as Vendor/build-guest-agents.sh builds the agent:
//!
//!   xcrun clang -c -O2 -fobjc-arc -arch arm64 -mmacosx-version-min=27.0 macos/screen.m -o /tmp/screen.o
//!   zig test macos/screen_test.zig /tmp/screen.o -lc --sysroot "$(xcrun --show-sdk-path)" \
//!     -F/System/Library/Frameworks -framework AppKit -framework ApplicationServices -framework Carbon
//!
//! from GuestAgent/src, with HUKAN_AGENT naming a built agent to put the child path through it.

const std = @import("std");
const testing = std.testing;
const json = std.json;
const agent = @import("../agent.zig");
const screen = @import("screen.zig");
const platform = @import("platform.zig");

var environ_map: std.process.Environ.Map = undefined;
var environ_ready = false;

fn makeAgent() agent.Agent {
    if (!environ_ready) {
        environ_map = std.process.Environ.Map.init(std.heap.smp_allocator);
        environ_ready = true;
    }
    return .{
        .mode = "user",
        .io = testing.io,
        .gpa = std.heap.smp_allocator,
        .environ = &environ_map,
        .search_path = platform.search_path,
        .extra = platform.extra,
    };
}

/// What the child answers to a request line, in this process.
fn once(arena: std.mem.Allocator, line: []const u8) json.ObjectMap {
    const a = makeAgent();
    const answer = platform.answerOnce(&a, arena, line);
    const text = json.Stringify.valueAlloc(arena, json.Value{ .object = answer }, .{}) catch unreachable;
    return (json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch unreachable).object;
}

test "clusters keep what rides on a character" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { []const u8, []const []const u8 }{
        .{ "ab", &.{ "a", "b" } },
        .{ "日本語", &.{ "日", "本", "語" } },
        .{ "e\u{301}x", &.{ "e\u{301}", "x" } }, // an accent typed apart
        .{ "\u{1F1EF}\u{1F1F5}\u{1F1FA}\u{1F1F8}", &.{ "\u{1F1EF}\u{1F1F5}", "\u{1F1FA}\u{1F1F8}" } }, // two flags
        .{ "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}!", &.{ "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", "!" } },
        .{ "\u{1F44D}\u{1F3FD}.", &.{ "\u{1F44D}\u{1F3FD}", "." } }, // a skin tone
        .{ "\u{2764}\u{FE0F}", &.{"\u{2764}\u{FE0F}"} }, // a variation selector
        .{ "が", &.{"が"} },
        .{ "か\u{3099}", &.{"か\u{3099}"} },
    };
    for (cases) |case| {
        const got = try screen.clusters(arena.allocator(), case[0]);
        try testing.expectEqual(case[1].len, got.len);
        for (case[1], got) |want, units| {
            const text = try std.unicode.utf16LeToUtf8Alloc(arena.allocator(), units);
            try testing.expectEqualStrings(want, text);
        }
    }
}

test "requests are refused before anything is posted or configured" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const refused = [_]struct { []const u8, []const u8 }{
        .{ "{\"op\":\"click\"}", "click needs x and y" },
        .{ "{\"op\":\"click\",\"x\":1.0}", "click needs x and y" },
        .{ "{\"op\":\"type\"}", "type needs text" },
        .{ "{\"op\":\"key\"}", "key needs a key" },
        .{ "{\"op\":\"key\",\"key\":\"nope\"}", "no key named nope" },
        .{ "{\"op\":\"key\",\"key\":\"a\",\"modifiers\":[\"hyper\"]}", "no modifier named hyper" },
        .{ "{\"op\":\"input_source\"}", "input_source needs an id" },
        .{ "{\"op\":\"input_source\",\"id\":\"no.such.source\",\"enable\":true}", "no input source no.such.source" },
        .{ "{\"op\":\"ui_press\",\"id\":\"x\"}", "no element x" },
        .{ "{\"op\":\"ui_set\",\"id\":\"x\"}", "no element x" },
        .{ "{\"op\":\"display\",\"width\":1920}", "display needs a width and a height" },
        .{ "{\"op\":\"display\",\"width\":1920.5,\"height\":1080}", "display needs a width and a height" },
        .{ "{\"op\":\"bogus\"}", "unknown op" },
        .{ "not json", "malformed request" },
    };
    for (refused) |case| {
        const answer = once(arena.allocator(), case[0]);
        try testing.expect(!answer.get("ok").?.bool);
        try testing.expectEqualStrings(case[1], answer.get("error").?.string);
    }
}

test "display refuses a size the panel is not" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // No panel is one pixel square, so this never reaches the configuration.
    const answer = once(arena.allocator(), "{\"op\":\"display\",\"width\":1,\"height\":1}");
    const message = answer.get("error").?.string;
    try testing.expect(!answer.get("ok").?.bool);
    try testing.expect(std.mem.startsWith(u8, message, "the panel is still ") or
        std.mem.startsWith(u8, message, "no mode draws 1x1") or
        std.mem.eql(u8, message, "the display lists no modes"));
}

test "windows are one a line, in screenshot pixels" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const answer = once(arena.allocator(), "{\"op\":\"windows\"}");
    try testing.expect(answer.get("ok").?.bool);
    var lines = std.mem.splitScalar(u8, answer.get("text").?.string, '\n');
    try testing.expectEqualStrings("id\tapp\ttitle\tframe", lines.next().?);
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = try std.fmt.parseInt(i64, fields.next().?, 10);
        try testing.expect(fields.next().?.len > 0);
        _ = fields.next().?;
        const frame = fields.next().?;
        try testing.expect(fields.next() == null);
        try testing.expect(frame[0] == '[' and frame[frame.len - 1] == ']');
        var parts = std.mem.tokenizeAny(u8, frame[1 .. frame.len - 1], ", x");
        var count: usize = 0;
        while (parts.next()) |part| : (count += 1) _ = try std.fmt.parseInt(i64, part, 10);
        try testing.expectEqual(@as(usize, 4), count);
    }
}

test "a tree is read, or refused for want of Accessibility" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const answer = once(arena.allocator(), "{\"op\":\"ui_tree\"}");
    if (answer.get("ok").?.bool) {
        try testing.expect(std.mem.startsWith(u8, answer.get("text").?.string, "app "));
        return;
    }
    const message = answer.get("error").?.string;
    try testing.expect(std.mem.eql(u8, message, "hukan-guest-agent does not have Accessibility in this guest") or
        std.mem.eql(u8, message, "no such application is running"));
}

// The child path, through a built agent: what it does not know comes back as its answer, not the
// silence of a child that answered nothing, and a request it does know is answered by it.
test "a screen request runs in a child and comes back" {
    const path = testing.environ.getPosix("HUKAN_AGENT") orelse return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    screen.helper_path = path;
    defer screen.helper_path = null;
    const a = makeAgent();
    const unknown = a.handleLine(arena.allocator(), "{\"op\":\"key\",\"key\":\"nope\"}");
    try testing.expectEqualStrings("no key named nope", unknown.get("error").?.string);
    const listed = a.handleLine(arena.allocator(), "{\"op\":\"windows\"}");
    try testing.expect(listed.get("ok").?.bool);
    try testing.expect(std.mem.startsWith(u8, listed.get("text").?.string, "id\tapp\ttitle\tframe"));

    var r: agent.Request = .{ .agent = &a, .arena = arena.allocator(), .value = .null };
    r.value = try json.parseFromSliceLeaky(json.Value, arena.allocator(), "{\"op\":\"bogus\"}", .{});
    const bogus = screen.runInChild(&r);
    try testing.expectEqualStrings("unknown op", bogus.get("error").?.string);
}
