//! The screen of a macOS guest: what the host's window-list, interface, click, type and key tools
//! ask for, through Accessibility and CoreGraphics, and the display mode and input source the host
//! sets. The screenshot itself is `screencapture`, run through exec.
//!
//!   {"op":"display","width":1920,"height":1200}    -> {"ok":true,"mode":"1920x1200@1"}
//!     (the main display's mode with exactly those pixels, at 1x)
//!   {"op":"windows"}                               -> {"ok":true,"text":"<one window a line>"}
//!   {"op":"ui_tree","app":?,"menus":?,"window":?}  -> {"ok":true,"text":"<one element a line>"}
//!   {"op":"ui_press","id":...,"action":?}          -> {"ok":true}
//!   {"op":"ui_set","id":...,"value":...}           -> {"ok":true}
//!   {"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//!   {"op":"type","text":...}                       -> {"ok":true}
//!   {"op":"key","key":"return","modifiers":["command"]?}  -> {"ok":true}
//!   {"op":"input_source","id":"com.apple.keylayout.ABC","enable":?}  -> {"ok":true}
//!     (select that input source, or with "enable" only turn it on)
//!
//! Every position is in the pixels of a screenshot — with "window", of that window's own.
//!
//! Each request is answered by a fresh copy of this program (`runInChild`), which is what
//! `perform` runs in; the system calls are screen.m's, declared here (`c`).

const std = @import("std");
const agent = @import("../agent.zig");
const Answer = agent.Answer;
const Request = agent.Request;

/// The requests answered here, each in a process of its own.
pub const ops = [_][]const u8{
    "display", "windows", "ui_tree", "ui_press", "ui_set", "click", "type", "key", "input_source",
};

pub fn handles(op: []const u8) bool {
    for (ops) |o| if (std.mem.eql(u8, o, op)) return true;
    return false;
}

/// The program a request is handed to; this one, unless a test says otherwise.
pub var helper_path: ?[]const u8 = null;

/// Has a fresh copy of this program answer a request about the screen. CoreGraphics reads a
/// process's displays once and brings them up to date from its run loop, which this one never runs:
/// the first call saw the panel as it stood, and every later one was told it was still that size,
/// however many times the host had resized it since. The same goes for what is frontmost.
pub fn runInChild(r: *Request) Answer {
    const io = r.agent.io;
    const body = std.json.Stringify.valueAlloc(r.arena, r.value, .{}) catch
        return r.failure("the request could not be encoded");
    const self = helper_path orelse (std.process.executablePathAlloc(io, r.arena) catch |err|
        return r.failuref("{t}", .{err}));

    agent.spawning.lockUncancelable(io);
    var child = std.process.spawn(io, .{
        .argv = &.{ self, "--once", body },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |err| {
        agent.spawning.unlock(io);
        return r.failuref("{t}", .{err});
    };
    agent.spawning.unlock(io);

    var output: std.ArrayList(u8) = .empty;
    var buffer: [16 << 10]u8 = undefined;
    while (true) {
        const n = child.stdout.?.readStreaming(io, &.{&buffer}) catch break;
        if (n == 0) break;
        output.appendSlice(r.arena, buffer[0..n]) catch break;
    }
    const term = child.wait(io) catch null;
    const code: i64 = if (term) |t| switch (t) {
        .exited => |e| e,
        else => -1,
    } else -1;
    const value = std.json.parseFromSliceLeaky(std.json.Value, r.arena, output.items, .{}) catch
        return r.failuref("the helper answered nothing (exit {d})", .{code});
    if (value != .object) return r.failuref("the helper answered nothing (exit {d})", .{code});
    return value.object;
}

/// What the child does with the one request it was started for.
pub fn perform(r: *Request) Answer {
    const op = r.text("op") orelse "";
    if (std.mem.eql(u8, op, "display")) {
        const width = r.integer("width");
        const height = r.integer("height");
        if (width == null or height == null) return r.failure("display needs a width and a height");
        return setDisplay(r, width.?, height.?);
    } else if (std.mem.eql(u8, op, "windows")) {
        return listWindows(r);
    } else if (std.mem.eql(u8, op, "ui_tree")) {
        return uiTree(r, r.text("app") orelse "", r.boolean("menus") orelse false, r.integer("window"));
    } else if (std.mem.eql(u8, op, "ui_press")) {
        return uiPress(r, r.text("id") orelse "", r.text("action") orelse "");
    } else if (std.mem.eql(u8, op, "ui_set")) {
        return uiSet(r, r.text("id") orelse "", r.text("value"));
    } else if (std.mem.eql(u8, op, "click")) {
        const x = r.number("x");
        const y = r.number("y");
        if (x == null or y == null) return r.failure("click needs x and y");
        return click(r, x.?, y.?, r.integer("count") orelse 1, r.boolean("right") orelse false, r.integer("window"));
    } else if (std.mem.eql(u8, op, "type")) {
        const text = r.text("text") orelse return r.failure("type needs text");
        return typeText(r, text);
    } else if (std.mem.eql(u8, op, "key")) {
        const key = r.text("key") orelse return r.failure("key needs a key");
        return press(r, key, r.field("modifiers"));
    } else if (std.mem.eql(u8, op, "input_source")) {
        const id = r.text("id") orelse return r.failure("input_source needs an id");
        return inputSource(r, id, r.boolean("enable") orelse false);
    }
    return r.failure("unknown op");
}

// MARK: The system, as screen.m and the frameworks give it

const Ref = ?*anyopaque;

const Window = extern struct {
    id: c_long,
    layer: c_long,
    pid: c_int,
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    owner: ?[*:0]u8,
    name: ?[*:0]u8,
};

const Mode = extern struct {
    mode: Ref,
    width: usize,
    height: usize,
    pixel_width: usize,
    pixel_height: usize,
    flags: u32,
};

const c = struct {
    extern fn hk_string(value: Ref) ?[*:0]u8;
    extern fn hk_number(value: Ref, out: *f64) c_int;
    extern fn hk_point(value: Ref, x: *f64, y: *f64) c_int;
    extern fn hk_size(value: Ref, width: *f64, height: *f64) c_int;
    extern fn hk_is_element(value: Ref) c_int;
    extern fn hk_attribute(element: Ref, name: [*:0]const u8) Ref;
    extern fn hk_element_at(x: f64, y: f64, pid: *c_int) Ref;
    extern fn hk_perform(element: Ref, action: [*:0]const u8) c_int;
    extern fn hk_set_value(element: Ref, value: [*:0]const u8) c_int;
    extern fn hk_windows(id: c_long, out: *?[*]Window) c_int;
    extern fn hk_free_windows(windows: ?[*]Window, count: c_int) void;
    extern fn hk_frontmost() c_int;
    extern fn hk_application(name: [*:0]const u8) c_int;
    extern fn hk_application_name(pid: c_int) ?[*:0]u8;
    extern fn hk_modes(out: *?[*]Mode) c_int;
    extern fn hk_free_modes(modes: ?[*]Mode, count: c_int) void;
    extern fn hk_set_mode(mode: Ref) c_int;
    extern fn hk_scale() f64;
    extern fn hk_post_mouse(kind: u32, x: f64, y: f64, button: u32, clicks: i64, flags: c_int) void;
    extern fn hk_post_unicode(units: [*]const u16, count: c_int, down: c_int) void;
    extern fn hk_post_key(code: u16, flags: u64, down: c_int) void;
    extern fn hk_post_released() void;
    extern fn hk_input_source(id: [*:0]const u8, enable: c_int) c_int;
    extern fn hk_cluster_end(units: [*]const u16, count: c_int, index: c_int) c_int;

    extern fn free(pointer: ?*anyopaque) void;
    extern fn CFRelease(value: Ref) void;
    extern fn CFGetTypeID(value: Ref) usize;
    extern fn CFArrayGetTypeID() usize;
    extern fn CFArrayGetCount(array: Ref) isize;
    extern fn CFArrayGetValueAtIndex(array: Ref, index: isize) Ref;
    extern fn AXUIElementCreateApplication(pid: c_int) Ref;
    extern fn AXUIElementCopyActionNames(element: Ref, names: *Ref) i32;
    extern fn AXIsProcessTrusted() u8;
};

const event = struct {
    const left_down = 1;
    const left_up = 2;
    const right_down = 3;
    const right_up = 4;
    const mouse_moved = 5;
    const button_left = 0;
    const button_right = 1;
    const shift: u64 = 0x20000;
    const control: u64 = 0x40000;
    const option: u64 = 0x80000;
    const command: u64 = 0x100000;
};

fn sleepMs(milliseconds: i64) void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = @intCast(milliseconds * std.time.ns_per_ms) };
    _ = std.c.nanosleep(&ts, null);
}

/// A C string the system handed over, copied into the arena and freed.
fn taken(r: *const Request, text: ?[*:0]u8) ?[]const u8 {
    const t = text orelse return null;
    defer c.free(t);
    return r.arena.dupe(u8, std.mem.span(t)) catch null;
}

fn release(value: Ref) void {
    if (value != null) c.CFRelease(value);
}

/// An attribute of an element, which the caller releases; null when it has none.
fn attribute(r: *const Request, element: Ref, name: []const u8) Ref {
    const key = r.arena.dupeSentinel(u8, name, 0) catch return null;
    return c.hk_attribute(element, key);
}

fn stringAttribute(r: *const Request, element: Ref, name: []const u8) ?[]const u8 {
    const value = attribute(r, element, name);
    defer release(value);
    return taken(r, c.hk_string(value));
}

const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

/// Where an element stands, in points, if it says.
fn frame(r: *const Request, element: Ref) ?Rect {
    const position = attribute(r, element, "AXPosition");
    defer release(position);
    const size = attribute(r, element, "AXSize");
    defer release(size);
    var f: Rect = .{};
    if (c.hk_point(position, &f.x, &f.y) == 0 or c.hk_size(size, &f.width, &f.height) == 0) return null;
    return f;
}

/// An element's children, held by the array the caller releases.
fn children(r: *const Request, element: Ref) struct { array: Ref, list: []Ref } {
    const value = attribute(r, element, "AXChildren");
    if (value == null or c.CFGetTypeID(value) != c.CFArrayGetTypeID()) {
        release(value);
        return .{ .array = null, .list = &.{} };
    }
    const count: usize = @intCast(@max(c.CFArrayGetCount(value), 0));
    const list = r.arena.alloc(Ref, count) catch return .{ .array = value, .list = &.{} };
    for (list, 0..) |*item, i| item.* = c.CFArrayGetValueAtIndex(value, @intCast(i));
    return .{ .array = value, .list = list };
}

/// A number of points or pixels as an integer: truncated toward zero, and never a panic.
fn whole(value: f64) i64 {
    if (std.math.isNan(value)) return 0;
    const clamped = std.math.clamp(value, -9.0e15, 9.0e15);
    return @intFromFloat(@trunc(clamped));
}

// MARK: Windows

const WindowInfo = struct {
    id: i64,
    layer: i64,
    pid: i64,
    bounds: Rect,
    owner: []const u8,
    name: []const u8,
};

/// What the window server knows of one window, or with id -1 of every window on screen.
fn windows(r: *const Request, id: i64) []WindowInfo {
    var list: ?[*]Window = null;
    const count: usize = @intCast(@max(c.hk_windows(@intCast(id), &list), 0));
    defer c.hk_free_windows(list, @intCast(count));
    const result = r.arena.alloc(WindowInfo, count) catch return &.{};
    for (result, 0..) |*out, i| {
        const w = list.?[i];
        out.* = .{
            .id = w.id,
            .layer = w.layer,
            .pid = w.pid,
            .bounds = .{ .x = w.x, .y = w.y, .width = w.width, .height = w.height },
            .owner = if (w.owner) |o| (r.arena.dupe(u8, std.mem.span(o)) catch "") else "",
            .name = if (w.name) |n| (r.arena.dupe(u8, std.mem.span(n)) catch "") else "",
        };
    }
    return result;
}

/// Pixels of a screenshot per point of the screen: AX and CGEvent speak points, and a screenshot is
/// what an agent reads positions off.
fn scale() f64 {
    return c.hk_scale();
}

fn listWindows(r: *Request) Answer {
    const s = scale();
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(r.arena, "id\tapp\ttitle\tframe") catch {};
    for (windows(r, -1)) |w| {
        if (w.layer != 0 or w.id < 0) continue;
        const owner = if (w.owner.len == 0) "?" else w.owner;
        text.print(r.arena, "\n{d}\t{s}\t{s}\t[{d},{d} {d}x{d}]", .{
            w.id,                       owner,                 w.name,
            whole(w.bounds.x * s),      whole(w.bounds.y * s), whole(w.bounds.width * s),
            whole(w.bounds.height * s),
        }) catch {};
    }
    return r.answer(.{ .ok = true, .text = @as([]const u8, text.items) });
}

fn applicationName(r: *const Request, pid: i64) []const u8 {
    return taken(r, c.hk_application_name(@intCast(pid))) orelse "";
}

// MARK: The interface, through Accessibility

/// The element an id names: its process and the child indices down to it, so nothing has to be
/// held between two calls — each is a process of its own. A window that has changed since it was
/// read lands the id on something else, which is why a tree is read again after anything moves.
/// Nothing is released: the process ends with the request.
fn elementById(r: *const Request, id: []const u8) Ref {
    const slash = std.mem.indexOfScalar(u8, id, '/') orelse return null;
    const pid = std.fmt.parseInt(c_int, id[0..slash], 10) catch return null;
    var current = c.AXUIElementCreateApplication(pid);
    var parts = std.mem.splitScalar(u8, id[slash + 1 ..], '.');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const index = std.fmt.parseInt(usize, part, 10) catch return null;
        const list = children(r, current).list;
        if (index >= list.len) return null;
        current = list[index];
    }
    return current;
}

fn clipped(arena: std.mem.Allocator, text: []const u8) []const u8 {
    const flat = std.mem.replaceOwned(u8, arena, text, "\n", " ") catch return text;
    var count: usize = 0;
    var it = std.unicode.Utf8View.initUnchecked(flat).iterator();
    while (it.nextCodepointSlice()) |_| {
        count += 1;
        if (count == 120) {
            if (it.i < flat.len) return std.mem.concat(arena, u8, &.{ flat[0..it.i], "…" }) catch flat;
            return flat;
        }
    }
    return flat;
}

fn near(a: Rect, b: Rect) bool {
    return @abs(a.x - b.x) < 1 and @abs(a.y - b.y) < 1 and
        @abs(a.width - b.width) < 1 and @abs(a.height - b.height) < 1;
}

const Tree = struct {
    r: *const Request,
    lines: std.ArrayList([]const u8) = .empty,
    origin: Rect,
    scale: f64,
    menus: bool,
    const limit = 2000;

    fn walk(t: *Tree, node: Ref, id: []const u8, depth: usize) void {
        const r = t.r;
        const a = r.arena;
        if (t.lines.items.len >= limit or depth >= 40) return;
        const role = stringAttribute(r, node, "AXRole") orelse "?";
        if (std.mem.eql(u8, role, "AXMenuBar") and !t.menus) return;
        var line: std.ArrayList(u8) = .empty;
        line.appendNTimes(a, ' ', depth) catch return;
        line.print(a, "{s} ", .{id}) catch return;
        line.appendSlice(a, std.mem.replaceOwned(u8, a, role, "AX", "") catch role) catch return;
        for ([_][]const u8{ "AXTitle", "AXDescription", "AXLabel" }) |key| {
            if (stringAttribute(r, node, key)) |text| if (text.len > 0) {
                line.print(a, " \"{s}\"", .{clipped(a, text)}) catch return;
                break;
            };
        }
        const value = attribute(r, node, "AXValue");
        if (value != null) {
            var number: f64 = 0;
            if (taken(r, c.hk_string(value))) |text| {
                if (text.len > 0) line.print(a, " value=\"{s}\"", .{clipped(a, text)}) catch {};
            } else if (c.hk_number(value, &number) != 0) {
                line.print(a, " value={d}", .{number}) catch {};
            }
            release(value);
        }
        if (frame(r, node)) |f| {
            line.print(a, " [{d},{d} {d}x{d}]", .{
                whole((f.x - t.origin.x) * t.scale), whole((f.y - t.origin.y) * t.scale),
                whole(f.width * t.scale),            whole(f.height * t.scale),
            }) catch {};
        }
        var actions: Ref = null;
        if (c.AXUIElementCopyActionNames(node, &actions) == 0 and actions != null) {
            // An app's own actions arrive as several lines of description, and are not names to
            // press.
            var names: std.ArrayList([]const u8) = .empty;
            const count: usize = @intCast(@max(c.CFArrayGetCount(actions), 0));
            for (0..count) |i| {
                const text = taken(r, c.hk_string(c.CFArrayGetValueAtIndex(actions, @intCast(i)))) orelse continue;
                if (std.mem.startsWith(u8, text, "AX"))
                    names.append(a, std.mem.replaceOwned(u8, a, text, "AX", "") catch text) catch {};
            }
            release(actions);
            if (names.items.len > 0) {
                const joined = std.mem.join(a, ",", names.items) catch "";
                line.print(a, " {{{s}}}", .{joined}) catch {};
            }
        }
        t.lines.append(a, line.items) catch return;
        const kids = children(r, node);
        defer release(kids.array);
        for (kids.list, 0..) |child, index| {
            const next = if (std.mem.endsWith(u8, id, "/"))
                std.fmt.allocPrint(a, "{s}{d}", .{ id, index }) catch return
            else
                std.fmt.allocPrint(a, "{s}.{d}", .{ id, index }) catch return;
            t.walk(child, next, depth + 1);
        }
    }
};

fn uiTree(r: *Request, name: []const u8, menus: bool, window_id: ?i64) Answer {
    if (c.AXIsProcessTrusted() == 0)
        return r.failure("hukan-guest-agent does not have Accessibility in this guest");
    // A window's tree is its application's, narrowed to the element standing where the window
    // server says that window is — AX has no public way to ask for a window by its number.
    var origin: Rect = .{};
    var target: WindowInfo = undefined;
    var pid: i64 = -1;
    if (window_id) |id| {
        const list = windows(r, id);
        if (list.len == 0 or list[0].pid < 0) return r.failuref("no window {d}", .{id});
        target = list[0];
        origin = target.bounds;
        pid = target.pid;
    } else if (name.len == 0) {
        pid = c.hk_frontmost();
    } else {
        const wanted = r.arena.dupeSentinel(u8, name, 0) catch return r.failure("out of memory");
        pid = c.hk_application(wanted);
    }
    if (pid < 0) return r.failure("no such application is running");
    const app_name = applicationName(r, pid);
    var tree: Tree = .{ .r = r, .origin = origin, .scale = scale(), .menus = menus };
    tree.lines.append(r.arena, std.fmt.allocPrint(r.arena, "app {s}", .{if (app_name.len == 0) "?" else app_name}) catch "app ?") catch {};

    const application = c.AXUIElementCreateApplication(@intCast(pid));
    const root = std.fmt.allocPrint(r.arena, "{d}/", .{pid}) catch return r.failure("out of memory");
    if (window_id) |id| {
        const list = children(r, application).list;
        var found: ?usize = null;
        for (list, 0..) |node, index| {
            const role = stringAttribute(r, node, "AXRole") orelse continue;
            if (!std.mem.eql(u8, role, "AXWindow")) continue;
            if (frame(r, node)) |f| if (near(f, target.bounds)) {
                found = index;
                break;
            };
        }
        const index = found orelse
            return r.failuref("window {d} is not in its application's interface", .{id});
        tree.walk(list[index], std.fmt.allocPrint(r.arena, "{s}{d}", .{ root, index }) catch root, 0);
    } else {
        tree.walk(application, root, 0);
    }
    if (tree.lines.items.len >= Tree.limit)
        tree.lines.append(r.arena, std.fmt.allocPrint(r.arena, "… cut at {d} lines", .{Tree.limit}) catch "") catch {};
    const text = std.mem.join(r.arena, "\n", tree.lines.items) catch "";
    return r.answer(.{ .ok = true, .text = text });
}

fn uiPress(r: *Request, id: []const u8, action: []const u8) Answer {
    const node = elementById(r, id) orelse return r.failuref("no element {s}", .{id});
    const name = std.fmt.allocPrintSentinel(r.arena, "AX{s}", .{if (action.len == 0) "Press" else action}, 0) catch
        return r.failure("out of memory");
    const code = c.hk_perform(node, name);
    if (code != 0) return r.failuref("{s} failed ({d})", .{ name, code });
    return r.ok();
}

fn uiSet(r: *Request, id: []const u8, value: ?[]const u8) Answer {
    const node = elementById(r, id);
    if (node == null or value == null) return r.failuref("no element {s}", .{id});
    const text = r.arena.dupeSentinel(u8, value.?, 0) catch return r.failure("out of memory");
    const code = c.hk_set_value(node, text);
    if (code != 0) return r.failuref("setting the value failed ({d})", .{code});
    return r.ok();
}

// MARK: Mouse and keyboard

fn click(r: *Request, x: f64, y: f64, count: i64, right: bool, window_id: ?i64) Answer {
    const s = scale();
    var px = x / s;
    var py = y / s;
    // Where the window is now rather than where it was when its picture was taken: a position in
    // the picture stays right however the window has been moved since.
    if (window_id) |id| {
        const list = windows(r, id);
        if (list.len == 0 or list[0].pid < 0) return r.failuref("no window {d}", .{id});
        const target = list[0];
        px += target.bounds.x;
        py += target.bounds.y;
        if (obstruction(r, px, py, id, target)) |problem| return r.failure(problem);
    }
    const down: u32, const up: u32, const button: u32 = if (right)
        .{ event.right_down, event.right_up, event.button_right }
    else
        .{ event.left_down, event.left_up, event.button_left };
    c.hk_post_mouse(event.mouse_moved, px, py, button, 0, 0);
    sleepMs(50);
    var number: i64 = 1;
    while (number <= @max(count, 1)) : (number += 1) {
        for ([_]u32{ down, up }) |kind| {
            c.hk_post_mouse(kind, px, py, button, number, 1);
            sleepMs(30);
        }
    }
    return r.ok();
}

/// Why a click meant for a window would land on something else, or null if it would not. A click
/// goes to whatever is on top at that point, and one aimed at a window the Dock was covering
/// started Safari, so it is asked what is there first.
fn obstruction(r: *const Request, x: f64, y: f64, id: i64, target: WindowInfo) ?[]const u8 {
    const a = r.arena;
    var pid: c_int = 0;
    const hit = c.hk_element_at(x, y, &pid);
    if (hit == null) return std.fmt.allocPrint(a, "that point of window {d} is off the screen", .{id}) catch "";
    var owner = applicationName(r, target.pid);
    if (owner.len == 0) owner = "its application";
    const raise = std.fmt.allocPrint(a, "; bring it to the front first (open -a {f}) or move it", .{quoted(owner)}) catch "";
    if (pid != target.pid) {
        var name = applicationName(r, pid);
        if (name.len == 0) name = "something else";
        return std.fmt.allocPrint(a, "that point of window {d} is covered by {s}{s}", .{ id, name, raise }) catch "";
    }
    // Same application: its other windows are told apart by where they stand.
    const other = attribute(r, hit, "AXWindow");
    defer release(other);
    if (c.hk_is_element(other) != 0) {
        const position = attribute(r, other, "AXPosition");
        defer release(position);
        var px: f64 = 0;
        var py: f64 = 0;
        if (c.hk_point(position, &px, &py) != 0 and
            (@abs(px - target.bounds.x) >= 1 or @abs(py - target.bounds.y) >= 1))
        {
            return std.fmt.allocPrint(a, "that point of window {d} is covered by another of its application's" ++
                " windows; move one of them first", .{id}) catch "";
        }
    }
    return null;
}

/// A string quoted with Go-style escapes (%q), which is what the host has always been told.
fn quoted(text: []const u8) Quoted {
    return .{ .text = text };
}

const Quoted = struct {
    text: []const u8,
    pub fn format(q: Quoted, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (q.text) |b| switch (b) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(b),
        };
        try w.writeByte('"');
    }
};

/// The text as what a person would call its characters, each a run of UTF-16: an accent typed
/// apart from its letter lands as a letter of its own, so a character goes as one event.
pub fn clusters(arena: std.mem.Allocator, text: []const u8) ![]const []const u16 {
    const units = try std.unicode.utf8ToUtf16LeAlloc(arena, text);
    var result: std.ArrayList([]const u16) = .empty;
    var i: usize = 0;
    while (i < units.len) {
        var end: usize = @intCast(c.hk_cluster_end(units.ptr, @intCast(units.len), @intCast(i)));
        if (end <= i or end > units.len) end = i + 1;
        try result.append(arena, units[i..end]);
        i = end;
    }
    return result.items;
}

fn typeText(r: *Request, text: []const u8) Answer {
    const characters = clusters(r.arena, text) catch return r.failure("type needs text");
    for (characters) |units| {
        for ([_]c_int{ 1, 0 }) |down| {
            c.hk_post_unicode(units.ptr, @intCast(units.len), down);
            sleepMs(8);
        }
    }
    return r.ok();
}

const key_codes = std.StaticStringMap(u16).initComptime(.{
    .{ "a", 0 },       .{ "s", 1 },       .{ "d", 2 },       .{ "f", 3 },        .{ "h", 4 },
    .{ "g", 5 },       .{ "z", 6 },       .{ "x", 7 },       .{ "c", 8 },        .{ "v", 9 },
    .{ "b", 11 },      .{ "q", 12 },      .{ "w", 13 },      .{ "e", 14 },       .{ "r", 15 },
    .{ "y", 16 },      .{ "t", 17 },      .{ "1", 18 },      .{ "2", 19 },       .{ "3", 20 },
    .{ "4", 21 },      .{ "6", 22 },      .{ "5", 23 },      .{ "=", 24 },       .{ "9", 25 },
    .{ "7", 26 },      .{ "-", 27 },      .{ "8", 28 },      .{ "0", 29 },       .{ "]", 30 },
    .{ "o", 31 },      .{ "u", 32 },      .{ "[", 33 },      .{ "i", 34 },       .{ "p", 35 },
    .{ "l", 37 },      .{ "j", 38 },      .{ "'", 39 },      .{ "k", 40 },       .{ ";", 41 },
    .{ "\\", 42 },     .{ ",", 43 },      .{ "/", 44 },      .{ "n", 45 },       .{ "m", 46 },
    .{ ".", 47 },      .{ "`", 50 },      .{ "return", 36 }, .{ "tab", 48 },     .{ "space", 49 },
    .{ "delete", 51 }, .{ "escape", 53 }, .{ "left", 123 },  .{ "right", 124 },  .{ "down", 125 },
    .{ "up", 126 },    .{ "home", 115 },  .{ "end", 119 },   .{ "pageup", 116 }, .{ "pagedown", 121 },
    .{ "f1", 122 },    .{ "f2", 120 },    .{ "f3", 99 },     .{ "f4", 118 },     .{ "f5", 96 },
    .{ "f6", 97 },     .{ "f7", 98 },     .{ "f8", 100 },    .{ "f9", 101 },     .{ "f10", 109 },
    .{ "f11", 103 },   .{ "f12", 111 },
});

fn press(r: *Request, key: []const u8, modifiers: ?std.json.Value) Answer {
    const lower = std.ascii.allocLowerString(r.arena, key) catch return r.failure("out of memory");
    const code = key_codes.get(lower) orelse return r.failuref("no key named {s}", .{key});
    var flags: u64 = 0;
    if (modifiers) |list| if (list == .array) for (list.array.items) |item| {
        if (item != .string) continue;
        const modifier = item.string;
        const m = std.ascii.allocLowerString(r.arena, modifier) catch return r.failure("out of memory");
        if (std.mem.eql(u8, m, "command") or std.mem.eql(u8, m, "cmd")) {
            flags |= event.command;
        } else if (std.mem.eql(u8, m, "shift")) {
            flags |= event.shift;
        } else if (std.mem.eql(u8, m, "option") or std.mem.eql(u8, m, "alt")) {
            flags |= event.option;
        } else if (std.mem.eql(u8, m, "control") or std.mem.eql(u8, m, "ctrl")) {
            flags |= event.control;
        } else {
            return r.failuref("no modifier named {s}", .{modifier});
        }
    };
    for ([_]c_int{ 1, 0 }) |down| {
        c.hk_post_key(code, flags, down);
        sleepMs(30);
    }
    // The window server takes the flags of the last event posted as what is held down, and a new
    // event starts from those: after ⌘A everything typed or clicked next was a ⌘-chord, so it did
    // nothing. Nothing is held once the key is up, so that is said too — and the events above and
    // in click and typeText set their own flags rather than inherit whatever was left.
    c.hk_post_released();
    return r.ok();
}

// MARK: The display

/// Puts the main display in the mode that draws exactly width x height pixels. The host sizes the
/// virtual panel; which mode the guest then uses on it is the guest's to choose, and it chooses the
/// way a MacBook does — a scaled "looks like" mode drawn larger and shrunk to fit — so a panel of
/// 1920x1200 drew at 2048x1280 and every screenshot came back that size. Of the modes with exactly
/// those pixels, the 1x one is taken: a held size is a desktop's size, the way it is on a Linux or
/// a Windows guest, where the HiDPI mode made 1920x1200 a 960x600 desktop — too small for the
/// windows an agent is there to try — and drew it twice as large in the tab.
fn setDisplay(r: *Request, width: i64, height: i64) Answer {
    var list: ?[*]Mode = null;
    const count: usize = @intCast(@max(c.hk_modes(&list), 0));
    defer c.hk_free_modes(list, @intCast(count));
    if (count == 0) return r.failure("the display lists no modes");
    const modes = list.?[0..count];
    // The panel first: until the guest has seen the host's resize, the old panel still lists a
    // scaled mode of these pixels, and taking it puts a shrunk picture on the wrong panel. The
    // native mode is the panel's own size.
    const native_flag = 0x0200_0000; // kDisplayModeNativeFlag
    for (modes) |mode| if (mode.flags & native_flag != 0) {
        if (mode.pixel_width != width or mode.pixel_height != height)
            return r.failuref("the panel is still {d}x{d}", .{ mode.pixel_width, mode.pixel_height });
        break;
    };
    var best: ?usize = null;
    var sizes: std.ArrayList([]const u8) = .empty;
    for (modes, 0..) |mode, index| {
        const size = std.fmt.allocPrint(r.arena, "{d}x{d}", .{ mode.pixel_width, mode.pixel_height }) catch continue;
        for (sizes.items) |s| {
            if (std.mem.eql(u8, s, size)) break;
        } else sizes.append(r.arena, size) catch {};
        if (mode.pixel_width == width and mode.pixel_height == height and
            (best == null or mode.width > modes[best.?].width)) best = index;
    }
    const chosen = best orelse {
        std.mem.sort([]const u8, sizes.items, {}, struct {
            fn less(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.less);
        const offered = std.mem.join(r.arena, " ", sizes.items) catch "";
        return r.failuref("no mode draws {d}x{d}; the display offers {s}", .{ width, height, offered });
    };
    const mode = modes[chosen];
    const code = c.hk_set_mode(mode.mode);
    if (code < 0) return r.failure("cannot configure the display");
    if (code != 0) return r.failuref("the display refused the mode ({d})", .{code});
    const text = std.fmt.allocPrint(r.arena, "{d}x{d}@{d}", .{
        mode.width, mode.height, mode.pixel_width / @max(mode.width, 1),
    }) catch "";
    return r.answer(.{ .ok = true, .mode = text });
}

// MARK: Input sources

/// The host's かな and 英数 keys, and the Japanese input a JIS keyboard expects. The guest's keyboard
/// is ANSI whatever the Mac's is — Virtualization.framework offers no other — and macOS ignores
/// those two keys from an ANSI keyboard, so the host asks for the input source instead.
fn inputSource(r: *Request, id: []const u8, enable: bool) Answer {
    const text = r.arena.dupeSentinel(u8, id, 0) catch return r.failure("out of memory");
    const status = c.hk_input_source(text, @intFromBool(enable));
    if (status == 0) return r.ok();
    if (status == 1) return r.failuref("no input source {s}", .{id});
    return r.failuref("input source {s}: {d}", .{ id, status });
}
