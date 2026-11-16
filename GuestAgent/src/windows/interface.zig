//! The interface of a Windows guest, for the user half of the agent: what is on the screen, through
//! UI Automation (uia.zig), and the mouse and keyboard, through SendInput. Positions are pixels of
//! a picture of the screen, or of one window's picture when a window is named.
//!
//!   {"op":"windows"}                         -> {"ok":true,"text":"<one window a line>"}
//!   {"op":"screenshot","window":id}          -> {"ok":true,"data":"<base64 PNG>"}
//!   {"op":"ui_tree","app":?,"window":?}      -> {"ok":true,"text":"<one element a line>"}
//!   {"op":"ui_press","element":...,"action":?}  -> {"ok":true}
//!   {"op":"ui_set","element":...,"value":...}   -> {"ok":true}
//!   {"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//!   {"op":"type","text":...}                 -> {"ok":true}
//!   {"op":"key","key":"return","modifiers":["control"]?}  -> {"ok":true}
//!   {"op":"clipboard_get"}                   -> {"ok":true,"text":...}
//!   {"op":"clipboard_set","text":...}        -> {"ok":true}
//!
//! An element is "element" rather than "id" here, the id being the request's.

const std = @import("std");
const agent = @import("../agent.zig");
const png = @import("../png.zig");
const text = @import("text.zig");
const uia = @import("uia.zig");
const w = @import("win32.zig");

const Request = agent.Request;
const Answer = agent.Answer;

fn sleep(r: *const Request, milliseconds: i64) void {
    std.Io.sleep(r.agent.io, .fromMilliseconds(milliseconds), .awake) catch {};
}

/// A window handle out of a request's number; null when there is no number there.
fn windowArgument(r: *const Request) ?w.HWND {
    const value = r.number("window") orelse return null;
    if (value < 1 or value >= 9.2e18) return @ptrFromInt(0x1); // no window answers to it
    return @ptrFromInt(@as(usize, @intFromFloat(value)));
}

fn handleNumber(window: w.HWND) usize {
    return @intFromPtr(window);
}

pub fn screen(r: *Request) ?Answer {
    const op = r.text("op") orelse return null;
    const is = struct {
        fn eql(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.eql;
    if (is(op, "windows")) return listWindows(r);
    if (is(op, "screenshot")) {
        const window = windowArgument(r) orelse return r.failure("screenshot needs a window");
        return screenshot(r, window);
    }
    if (is(op, "ui_tree")) return uia.tree(r, r.text("app") orelse "", windowArgument(r));
    if (is(op, "ui_press")) return uia.press(r, r.text("element") orelse "", r.text("action") orelse "");
    if (is(op, "ui_set")) return uia.set(r, r.text("element") orelse "", r.text("value") orelse "");
    if (is(op, "click")) {
        const x = r.number("x") orelse return r.failure("click needs x and y");
        const y = r.number("y") orelse return r.failure("click needs x and y");
        const count: i64 = if (r.number("count")) |c| @intFromFloat(std.math.clamp(c, -1e6, 1e6)) else 1;
        return click(r, x, y, count, r.boolean("right") orelse false, windowArgument(r));
    }
    if (is(op, "type")) {
        const value = r.text("text") orelse return r.failure("type needs text");
        return typeText(r, value);
    }
    if (is(op, "key")) {
        const name = r.text("key") orelse return r.failure("key needs a key");
        var modifiers: std.ArrayList([]const u8) = .empty;
        if (r.field("modifiers")) |list| if (list == .array) for (list.array.items) |item| {
            if (item == .string) modifiers.append(r.arena, item.string) catch {};
        };
        return press(r, name, modifiers.items);
    }
    if (is(op, "clipboard_get")) return clipboardGet(r);
    if (is(op, "clipboard_set")) return clipboardSet(r, r.text("text") orelse "");
    return null;
}

// MARK: Windows

pub fn windowRect(window: w.HWND) ?w.RECT {
    var rect: w.RECT = .{};
    if (w.GetWindowRect(window, &rect) == 0) return null;
    return rect;
}

pub fn title(arena: std.mem.Allocator, window: w.HWND) []const u8 {
    var buffer: [512]u16 = undefined;
    const length = w.GetWindowTextW(window, &buffer, buffer.len);
    if (length <= 0) return "";
    return text.fromWide(arena, buffer[0..@intCast(length)]);
}

pub fn windowProcess(window: w.HWND) u32 {
    var pid: w.DWORD = 0;
    _ = w.GetWindowThreadProcessId(window, &pid);
    return pid;
}

/// A process's executable without its extension, the way Task Manager names it; "" when it cannot
/// be asked.
pub fn processName(arena: std.mem.Allocator, pid: u32) []const u8 {
    const process = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return "";
    defer _ = w.CloseHandle(process);
    var buffer: [32768]u16 = undefined;
    var size: w.DWORD = buffer.len;
    if (w.QueryFullProcessImageNameW(process, 0, &buffer, &size) == 0) return "";
    const path = text.fromWide(arena, buffer[0..size]);
    const base = path[(if (std.mem.lastIndexOfAny(u8, path, "\\/")) |i| i + 1 else 0)..];
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
}

/// Visits the top-level windows front to back until `visit` says stop.
pub fn eachWindow(context: anytype, comptime visit: fn (@TypeOf(context), w.HWND) bool) void {
    const Context = @TypeOf(context);
    const Trampoline = struct {
        fn call(window: w.HWND, parameter: w.LPARAM) callconv(.winapi) w.BOOL {
            const c: *const Context = @ptrFromInt(@as(usize, @bitCast(parameter)));
            return @intFromBool(visit(c.*, window));
        }
    };
    _ = w.EnumWindows(Trampoline.call, @bitCast(@intFromPtr(&context)));
}

fn listWindows(r: *Request) Answer {
    var lines: std.ArrayList(u8) = .empty;
    lines.appendSlice(r.arena, "id\tapp\ttitle\tframe") catch {};
    const Lister = struct {
        r: *Request,
        lines: *std.ArrayList(u8),
        fn visit(self: @This(), window: w.HWND) bool {
            const arena = self.r.arena;
            const name = title(arena, window);
            const rect = windowRect(window) orelse return true;
            if (w.IsWindowVisible(window) == 0 or name.len == 0) return true;
            if (rect.right - rect.left <= 1 or rect.bottom - rect.top <= 1) return true;
            var app = processName(arena, windowProcess(window));
            if (app.len == 0) app = "?";
            const line = std.fmt.allocPrint(arena, "\n{d}\t{s}\t{s}\t[{d},{d} {d}x{d}]", .{
                handleNumber(window),   app,      text.clip(arena, name),
                rect.left,              rect.top, rect.right - rect.left,
                rect.bottom - rect.top,
            }) catch return true;
            self.lines.appendSlice(arena, line) catch {};
            return true;
        }
    };
    eachWindow(Lister{ .r = r, .lines = &lines }, Lister.visit);
    return r.answer(.{ .ok = true, .text = lines.items });
}

/// A window's own picture: PrintWindow reads what it draws, so one covered by another comes out
/// whole.
fn screenshot(r: *Request, window: w.HWND) Answer {
    const rect = windowRect(window);
    if (w.IsWindow(window) == 0 or rect == null) return r.failuref("no window {d}", .{handleNumber(window)});
    const width = rect.?.right - rect.?.left;
    const height = rect.?.bottom - rect.?.top;
    if (width <= 0 or height <= 0) return r.failuref("window {d} has no size", .{handleNumber(window)});
    const context = w.CreateCompatibleDC(null) orelse return r.failure("no drawing context");
    defer _ = w.DeleteDC(context);
    // Top-down, 32-bit: rows in reading order, pixels as BGRX.
    const header: w.BITMAPINFOHEADER = .{ .width = width, .height = -height };
    var bits: ?*anyopaque = null;
    const bitmap = w.CreateDIBSection(context, &header, w.DIB_RGB_COLORS, &bits, null, 0) orelse
        return r.failure("no bitmap");
    defer _ = w.DeleteObject(bitmap);
    const previous = w.SelectObject(context, bitmap);
    const drawn = w.PrintWindow(window, context, w.PW_RENDERFULLCONTENT);
    if (previous) |p| _ = w.SelectObject(context, p);
    if (drawn == 0 or bits == null) return r.failuref("window {d} could not be drawn", .{handleNumber(window)});

    const pixels: usize = @as(usize, @intCast(width)) * @as(usize, @intCast(height));
    const source: [*]const u8 = @ptrCast(bits.?);
    const rgba = r.arena.alloc(u8, pixels * 4) catch return r.failure("out of memory");
    for (0..pixels) |i| {
        rgba[i * 4 + 0] = source[i * 4 + 2];
        rgba[i * 4 + 1] = source[i * 4 + 1];
        rgba[i * 4 + 2] = source[i * 4 + 0];
        rgba[i * 4 + 3] = 255;
    }
    const encoded = png.encode(r.arena, @intCast(width), @intCast(height), rgba) catch |err|
        return r.failuref("the picture could not be encoded: {t}", .{err});
    return r.answer(.{ .ok = true, .data = r.encode(encoded) });
}

// MARK: Mouse and keyboard

fn send(inputs: []const w.INPUT) void {
    _ = w.SendInput(@intCast(inputs.len), inputs.ptr, @sizeOf(w.INPUT));
}

fn mouse(flags: w.DWORD) w.INPUT {
    return .{ .kind = w.INPUT_MOUSE, .data = .{ .mouse = .{ .flags = flags } } };
}

fn key(vk: u16, scan: u16, flags: w.DWORD) w.INPUT {
    return .{ .kind = w.INPUT_KEYBOARD, .data = .{ .key = .{ .vk = vk, .scan = scan, .flags = flags } } };
}

fn toInt(value: f64) i32 {
    return @intFromFloat(std.math.clamp(@trunc(value), -2147483648.0, 2147483647.0));
}

fn click(r: *Request, x: f64, y: f64, count: i64, right: bool, window: ?w.HWND) Answer {
    var px = toInt(x);
    var py = toInt(y);
    if (window) |handle| {
        const rect = windowRect(handle);
        if (w.IsWindow(handle) == 0 or rect == null) return r.failuref("no window {d}", .{handleNumber(handle)});
        px +|= rect.?.left;
        py +|= rect.?.top;
        if (px >= rect.?.right or py >= rect.?.bottom or px < rect.?.left or py < rect.?.top)
            return r.failuref("that point of window {d} is outside it", .{handleNumber(handle)});
        // A click goes to whatever is on top there, which is not necessarily the window asked for.
        const hit = w.WindowFromPoint(.{ .x = px, .y = py });
        const top = if (hit) |h| w.GetAncestor(h, w.GA_ROOT) else null;
        if (top != handle) {
            const name = if (top) |t| title(r.arena, t) else "";
            return r.failuref("that point of window {d} is covered by \"{s}\"; bring it to the front first", .{
                handleNumber(handle), text.clip(r.arena, name),
            });
        }
    }
    _ = w.SetCursorPos(px, py);
    sleep(r, 50);
    const down = if (right) w.MOUSEEVENTF_RIGHTDOWN else w.MOUSEEVENTF_LEFTDOWN;
    const up = if (right) w.MOUSEEVENTF_RIGHTUP else w.MOUSEEVENTF_LEFTUP;
    var i: i64 = 0;
    while (i < @max(count, 1)) : (i += 1) {
        send(&.{mouse(down)});
        sleep(r, 30);
        send(&.{mouse(up)});
        sleep(r, 30);
    }
    return r.ok();
}

fn typeText(r: *Request, value: []const u8) Answer {
    const units = std.unicode.utf8ToUtf16LeAlloc(r.arena, value) catch return r.failure("type needs text");
    for (units) |unit| {
        send(&.{key(0, unit, w.KEYEVENTF_UNICODE)});
        send(&.{key(0, unit, w.KEYEVENTF_UNICODE | w.KEYEVENTF_KEYUP)});
        sleep(r, 8);
    }
    return r.ok();
}

/// The character a one-character key name is, if it is one VkKeyScanW can be asked about.
fn single(name: []const u8) ?u16 {
    const view = std.unicode.Utf8View.init(name) catch return null;
    var it = view.iterator();
    const first = it.nextCodepoint() orelse return null;
    if (it.nextCodepoint() != null or first > 0xFFFF) return null;
    return @intCast(first);
}

fn press(r: *Request, name: []const u8, modifiers: []const []const u8) Answer {
    var code: u16 = undefined;
    var held: std.ArrayList(u16) = .empty;
    if (text.keyCode(name)) |named| {
        code = named;
    } else if (single(name)) |character| {
        const scan: u16 = @bitCast(w.VkKeyScanW(character));
        if (scan == 0xFFFF) return r.failuref("no key named {s}", .{name});
        code = scan & 0xFF;
        // A symbol's key is the layout's, and on some layouts it takes Shift to reach.
        if (scan & 0x100 != 0) held.append(r.arena, 0x10) catch {};
    } else {
        return r.failuref("no key named {s}", .{name});
    }
    for (modifiers) |modifier| {
        const vk = text.modifierCode(modifier) orelse return r.failuref("no modifier named {s}", .{modifier});
        held.append(r.arena, vk) catch {};
    }
    for (held.items) |vk| send(&.{key(vk, 0, 0)});
    send(&.{key(code, 0, 0)});
    sleep(r, 30);
    send(&.{key(code, 0, w.KEYEVENTF_KEYUP)});
    var i = held.items.len;
    while (i > 0) {
        i -= 1;
        send(&.{key(held.items[i], 0, w.KEYEVENTF_KEYUP)});
    }
    return r.ok();
}

// MARK: Clipboard

/// Waits a moment for whoever has the clipboard open to let it go.
fn openClipboard(r: *const Request) bool {
    for (0..20) |_| {
        if (w.OpenClipboard(null) != 0) return true;
        sleep(r, 25);
    }
    return false;
}

fn clipboardGet(r: *Request) Answer {
    if (!openClipboard(r)) return r.failure("the clipboard is held by another program");
    defer _ = w.CloseClipboard();
    var value: []const u8 = "";
    if (w.IsClipboardFormatAvailable(w.CF_UNICODETEXT) != 0) {
        if (w.GetClipboardData(w.CF_UNICODETEXT)) |data| {
            if (w.GlobalLock(data)) |pointer| {
                const units: [*:0]const u16 = @ptrCast(@alignCast(pointer));
                value = text.fromWide(r.arena, std.mem.span(units));
                _ = w.GlobalUnlock(data);
            }
        }
    }
    return r.answer(.{ .ok = true, .text = value });
}

fn clipboardSet(r: *Request, value: []const u8) Answer {
    if (!openClipboard(r)) return r.failure("the clipboard is held by another program");
    defer _ = w.CloseClipboard();
    _ = w.EmptyClipboard();
    if (value.len == 0) return r.ok();
    if (std.mem.indexOfScalar(u8, value, 0) != null) return r.failure("the text holds a NUL");
    const units = std.unicode.utf8ToUtf16LeAllocZ(r.arena, value) catch return r.failure("the text holds a NUL");
    const size = (units.len + 1) * 2;
    const memory = w.GlobalAlloc(w.GMEM_MOVEABLE, size) orelse return r.failure("out of memory for the clipboard");
    const pointer = w.GlobalLock(memory) orelse {
        _ = w.GlobalFree(memory);
        return r.failure("out of memory for the clipboard");
    };
    const destination: [*]u16 = @ptrCast(@alignCast(pointer));
    @memcpy(destination[0 .. units.len + 1], units[0 .. units.len + 1]);
    _ = w.GlobalUnlock(memory);
    // The clipboard owns the memory once it has taken it, and not before.
    if (w.SetClipboardData(w.CF_UNICODETEXT, memory) == null) {
        _ = w.GlobalFree(memory);
        return r.failure("the clipboard refused the text");
    }
    return r.ok();
}
