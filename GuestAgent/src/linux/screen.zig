//! The screen of a Linux guest, for the user half: what the host's screenshot, click, type, key and
//! window-list tools ask for, answered over the X11 protocol itself — the core protocol for pictures
//! and windows, XTEST for input — so the guest needs nothing installed for it. X11 only: a session
//! on Wayland is answered by shell.zig instead.
//!
//!   {"op":"screenshot","window":?}                 -> {"ok":true,"data":"<base64 PNG>"}
//!   {"op":"windows"}                               -> {"ok":true,"text":"<id\tapp\ttitle\tx,y wxh a line>"}
//!   {"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//!   {"op":"type","text":...}                       -> {"ok":true}
//!   {"op":"key","key":"return","modifiers":["command"]?}  -> {"ok":true}
//!
//! Positions are in the pixels of a screenshot — of that window's own, given a window — which on
//! X11 are the screen's own pixels.

const std = @import("std");
const agent = @import("../agent.zig");
const png = @import("../png.zig");
const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const Display = @import("x11.zig").Display;

pub fn handles(op: []const u8) bool {
    for ([_][]const u8{ "screenshot", "windows", "click", "type", "key" }) |name| {
        if (std.mem.eql(u8, op, name)) return true;
    }
    return false;
}

pub fn answer(r: *agent.Request, op: []const u8) agent.Answer {
    var d = switch (Display.open(r.arena, r.agent.io, r.agent.environ)) {
        .display => |display| display,
        .failure => |message| return r.failure(message),
    };
    defer d.close();
    if (std.mem.eql(u8, op, "screenshot")) return screenshot(r, &d);
    if (std.mem.eql(u8, op, "windows")) return windows(r, &d);
    if (std.mem.eql(u8, op, "click")) return click(r, &d);
    if (std.mem.eql(u8, op, "type")) return typeText(r, &d);
    return key(r, &d);
}

const Frame = struct { x: i32, y: i32, width: u16, height: u16 };

/// Where a window's top-left is on the screen and its size, or the screen's own for none.
fn origin(d: *Display, window: ?u32) union(enum) { frame: Frame, failure: []const u8 } {
    const arena = d.arena;
    if (window) |w| {
        const geometry = d.call(protocol.getGeometry(arena, w)) catch
            return .{ .failure = std.fmt.allocPrint(arena, "no window {d}", .{w}) catch "" };
        const at = d.call(protocol.translateCoordinates(arena, w, d.root, 0, 0)) catch |err|
            return .{ .failure = d.describe(err) };
        return .{ .frame = .{
            .x = @as(i16, @bitCast(protocol.read(u16, at, 12))),
            .y = @as(i16, @bitCast(protocol.read(u16, at, 14))),
            .width = protocol.read(u16, geometry, 16),
            .height = protocol.read(u16, geometry, 18),
        } };
    }
    const geometry = d.call(protocol.getGeometry(arena, d.root)) catch |err|
        return .{ .failure = d.describe(err) };
    return .{ .frame = .{ .x = 0, .y = 0, .width = protocol.read(u16, geometry, 16), .height = protocol.read(u16, geometry, 18) } };
}

/// The window a request names, if it names one.
fn requestedWindow(r: *agent.Request) ?u32 {
    const value = r.number("window") orelse return null;
    if (value < 0 or value > std.math.maxInt(u32)) return null;
    return @intFromFloat(value);
}

/// A screenshot is read off the screen where the window stands, so what covers it is in the
/// picture: without a compositor, X keeps no picture of the covered part of a window.
///
/// The screen is read only where the window and the screen overlap — X refuses a rectangle that
/// runs off the screen, and a window does: GNOME places one with its shadow above the top edge —
/// and what lies off the screen is black. The picture stays the window's size, so a position in it
/// is still a position in the window, which is what a click on the window is given.
fn screenshot(r: *agent.Request, d: *Display) agent.Answer {
    const window = requestedWindow(r);
    const frame = switch (origin(d, window)) {
        .frame => |f| f,
        .failure => |message| return r.failure(message),
    };
    const screen = switch (origin(d, null)) {
        .frame => |f| f,
        .failure => |message| return r.failure(message),
    };
    const left = @max(frame.x, 0);
    const top = @max(frame.y, 0);
    const right = @min(frame.x + @as(i32, frame.width), @as(i32, screen.width));
    const bottom = @min(frame.y + @as(i32, frame.height), @as(i32, screen.height));
    if (right <= left or bottom <= top)
        return r.failuref("window {d} is not on the screen", .{window orelse 0});
    const seen_width: u16 = @intCast(right - left);
    const seen_height: u16 = @intCast(bottom - top);

    const reply = d.call(protocol.getImage(r.arena, d.root, @intCast(left), @intCast(top), seen_width, seen_height)) catch |err|
        return r.failuref("the screen could not be read: {s}", .{d.describe(err)});
    const seen = @as(usize, seen_width) * seen_height;
    // Depth 24 comes as 32 bits a pixel, blue first.
    if (reply.len < 32 + seen * 4) return r.failure("the screen is not 32 bits a pixel");
    const part = r.arena.alloc(u8, seen * 4) catch return r.failure("out of memory");
    protocol.bgrxToRgba(reply[32..][0 .. seen * 4], part);

    const width: usize = frame.width;
    const rgba = r.arena.alloc(u8, width * frame.height * 4) catch return r.failure("out of memory");
    for (0..@as(usize, frame.width) * frame.height) |i| rgba[i * 4 ..][0..4].* = .{ 0, 0, 0, 255 };
    const offset_x: usize = @intCast(left - frame.x);
    const offset_y: usize = @intCast(top - frame.y);
    for (0..seen_height) |row| {
        const from = part[row * seen_width * 4 ..][0 .. @as(usize, seen_width) * 4];
        @memcpy(rgba[((offset_y + row) * width + offset_x) * 4 ..][0..from.len], from);
    }
    const encoded = png.encode(r.arena, frame.width, frame.height, rgba) catch |err|
        return r.failuref("{t}", .{err});
    return r.answer(.{ .ok = true, .data = r.encode(encoded) });
}

fn atom(d: *Display, name: []const u8) u32 {
    const reply = d.call(protocol.internAtom(d.arena, name, true)) catch return protocol.atom_none;
    return protocol.read(u32, reply, 8);
}

fn property(d: *Display, window: u32, name: []const u8, kind: u32) []const u8 {
    const reply = d.call(protocol.getProperty(d.arena, window, atom(d, name), kind, 1 << 16)) catch return &.{};
    return protocol.propertyValue(reply);
}

/// The window manager's clients, front to back, as EWMH has them stacked.
fn windows(r: *agent.Request, d: *Display) agent.Answer {
    const stacked = property(d, d.root, "_NET_CLIENT_LIST_STACKING", protocol.atom_window);
    var lines: std.ArrayList(u8) = .empty;
    const utf8 = atom(d, "UTF8_STRING");
    var i = stacked.len / 4;
    while (i > 0) {
        i -= 1;
        const window = protocol.read(u32, stacked, i * 4);
        var title = property(d, window, "_NET_WM_NAME", utf8);
        if (title.len == 0) title = property(d, window, "WM_NAME", protocol.atom_string);
        // WM_CLASS is the instance and the class, each ending in a NUL; the class names the app.
        const class = std.mem.trimEnd(u8, property(d, window, "WM_CLASS", protocol.atom_string), "\x00");
        const app = if (std.mem.lastIndexOfScalar(u8, class, 0)) |nul| class[nul + 1 ..] else class;
        const frame = switch (origin(d, window)) {
            .frame => |f| f,
            .failure => continue,
        };
        const flat = std.mem.replaceOwned(u8, r.arena, title, "\t", " ") catch title;
        if (lines.items.len > 0) lines.append(r.arena, '\n') catch {};
        lines.print(r.arena, "{d}\t{s}\t{s}\t{d},{d} {d}x{d}", .{ window, app, flat, frame.x, frame.y, frame.width, frame.height }) catch {};
    }
    return r.answer(.{ .ok = true, .text = @as([]const u8, lines.items) });
}

/// A position rounded half up, as the host has always had it rounded.
fn rounded(value: f64) i64 {
    return @intFromFloat(@floor(value + 0.5));
}

fn click(r: *agent.Request, d: *Display) agent.Answer {
    const x = r.number("x");
    const y = r.number("y");
    if (x == null or y == null) return r.failure("click needs x and y");
    const frame = switch (origin(d, requestedWindow(r))) {
        .frame => |f| f,
        .failure => |message| return r.failure(message),
    };
    const button: u8 = if (r.boolean("right") orelse false) 3 else 1;
    var count: i64 = 1;
    if (r.number("count")) |value| {
        const c = rounded(value);
        if (c > 1) count = c;
    }
    const at_x: i16 = @truncate(frame.x + rounded(x.?));
    const at_y: i16 = @truncate(frame.y + rounded(y.?));
    d.send(protocol.fakeInput(r.arena, d.xtest, protocol.motion_notify, 0, d.root, at_x, at_y)) catch |err|
        return r.failure(d.describe(err));
    var i: i64 = 0;
    while (i < count) : (i += 1) {
        d.send(protocol.fakeInput(r.arena, d.xtest, protocol.button_press, button, d.root, 0, 0)) catch |err|
            return r.failure(d.describe(err));
        d.send(protocol.fakeInput(r.arena, d.xtest, protocol.button_release, button, d.root, 0, 0)) catch |err|
            return r.failure(d.describe(err));
    }
    return synced(r, d);
}

/// The answer once the server has taken every event sent.
fn synced(r: *agent.Request, d: *Display) agent.Answer {
    d.sync() catch |err| return r.failure(d.describe(err));
    return r.ok();
}

fn press(d: *Display, code: u8) void {
    d.send(protocol.fakeInput(d.arena, d.xtest, protocol.key_press, code, d.root, 0, 0)) catch {};
}

fn release(d: *Display, code: u8) void {
    d.send(protocol.fakeInput(d.arena, d.xtest, protocol.key_release, code, d.root, 0, 0)) catch {};
}

fn sleep(d: *Display, milliseconds: i64) void {
    std.Io.sleep(d.io, .fromMilliseconds(milliseconds), .awake) catch {};
}

/// What no key types is typed on a keycode nothing is mapped to, given that character for the
/// stroke, the way xdotool does it. A client reads a key by the mapping it holds when it gets to
/// the event, which can be after the mapping has moved on: with one spare keycode remapped for each
/// character and put back straight after, テスト arrived as ストト. So each character takes a spare
/// of its own, in turn round all of them, and keeps it while the text is typed — a character met
/// again is typed on the key it already has — and they are emptied only once the last stroke has
/// had time to be read.
fn typeText(r: *agent.Request, d: *Display) agent.Answer {
    const text = r.text("text") orelse return r.failure("type needs text");
    const view = std.unicode.Utf8View.init(text) catch return r.failure("type needs text");
    const shift: ?u8 = if (d.keyboard.keycode(keys.shift_l)) |found| found.code else null;

    var spare_buffer: [256]u8 = undefined;
    const spares = d.keyboard.spares(&spare_buffer);
    var given: [256]u32 = @splat(0); // the keysym each spare holds now
    var next_spare: usize = 0;
    var used: usize = 0;
    const column = r.arena.alloc(u32, d.keyboard.per) catch return r.failure("out of memory");
    defer if (used > 0) {
        // A beat for the last strokes to be read, then every spare back to nothing.
        d.sync() catch {};
        sleep(d, 100);
        @memset(column, 0);
        for (spares[0..used]) |code| d.send(protocol.changeKeyboardMapping(r.arena, code, column)) catch {};
        d.sync() catch {};
    };

    var it = view.iterator();
    while (it.nextCodepointSlice()) |character| {
        const codepoint = std.unicode.utf8Decode(character) catch unreachable;
        const keysym = keys.runeKeysym(codepoint);
        const found = d.keyboard.keycode(keysym) orelse {
            if (spares.len == 0) return r.failuref("no free key to type {s} with", .{character});
            const held = std.mem.indexOfScalar(u32, given[0..spares.len], keysym);
            const index = held orelse blk: {
                const index = next_spare;
                next_spare = (next_spare + 1) % spares.len;
                // Round all of them once already: the stroke this spare carried last must have
                // been read before the spare is given another character.
                if (used == spares.len) {
                    d.sync() catch {};
                    sleep(d, 100);
                }
                used = @max(used, index + 1);
                // Both columns, or a letter given alone is read as its lower and upper case.
                @memset(column, 0);
                column[0] = keysym;
                if (column.len > 1) column[1] = keysym;
                d.send(protocol.changeKeyboardMapping(r.arena, spares[index], column)) catch {};
                given[index] = keysym;
                d.sync() catch {};
                // The mapping reaches the clients as an event they act on; a beat lets them.
                sleep(d, 30);
                break :blk index;
            };
            press(d, spares[index]);
            release(d, spares[index]);
            d.sync() catch {};
            sleep(d, 8);
            continue;
        };
        const shifted = found.shifted and shift != null;
        if (shifted) press(d, shift.?);
        press(d, found.code);
        release(d, found.code);
        if (shifted) release(d, shift.?);
        d.sync() catch {};
        sleep(d, 8);
    }
    return synced(r, d);
}

fn key(r: *agent.Request, d: *Display) agent.Answer {
    const name = r.text("key") orelse "";
    var buffer: [64]u8 = undefined;
    const keysym = keys.keysymFor(&buffer, name) orelse return r.failuref("unknown key {s}", .{name});
    const code = (d.keyboard.keycode(keysym) orelse
        return r.failuref("no key on this keyboard types {s}", .{name})).code;
    var held: std.ArrayList(u8) = .empty;
    if (r.field("modifiers")) |list| if (list == .array) {
        for (list.array.items) |item| {
            const modifier = if (item == .string) item.string else "";
            const modifier_keysym = keys.modifierKeysym(&buffer, modifier) orelse
                return r.failuref("unknown modifier {s}", .{modifier});
            if (d.keyboard.keycode(modifier_keysym)) |found| held.append(r.arena, found.code) catch {};
        }
    };
    for (held.items) |modifier| press(d, modifier);
    press(d, code);
    release(d, code);
    var i = held.items.len;
    while (i > 0) {
        i -= 1;
        release(d, held.items[i]);
    }
    return synced(r, d);
}
