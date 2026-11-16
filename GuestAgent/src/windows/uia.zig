//! UI Automation, called through its COM interfaces directly: each call is a slot in the object's
//! table of methods, and the slot numbers and GUIDs below are UIAutomationClient.h's (checked
//! against mingw-w64's copy of it). An element is named by its window and the child positions down
//! to it, as in the macOS agent, so nothing is held between two requests.

const std = @import("std");
const agent = @import("../agent.zig");
const interface = @import("interface.zig");
const text = @import("text.zig");
const w = @import("win32.zig");

const Request = agent.Request;
const Answer = agent.Answer;
const HRESULT = w.HRESULT;

const clsid_CUIAutomation: w.GUID = .{ .data1 = 0xff48dba4, .data2 = 0x60ef, .data3 = 0x4201, .data4 = .{ 0xaa, 0x87, 0x54, 0x10, 0x3e, 0xef, 0x59, 0x4e } };
const iid_IUIAutomation: w.GUID = .{ .data1 = 0x30cbe57d, .data2 = 0xd9d0, .data3 = 0x452a, .data4 = .{ 0xab, 0x13, 0x7a, 0xc5, 0xac, 0x48, 0x25, 0xee } };
const iid_InvokePattern: w.GUID = .{ .data1 = 0xfb377fbe, .data2 = 0x8ea6, .data3 = 0x46d5, .data4 = .{ 0x9c, 0x73, 0x64, 0x99, 0x64, 0x2d, 0x30, 0x59 } };
const iid_TogglePattern: w.GUID = .{ .data1 = 0x94cf8058, .data2 = 0x9b8d, .data3 = 0x4ab9, .data4 = .{ 0x8b, 0xfd, 0x4c, 0xd0, 0xa3, 0x3c, 0x8c, 0x70 } };
const iid_SelectionItemPattern: w.GUID = .{ .data1 = 0xa8efa66a, .data2 = 0x0fda, .data3 = 0x421a, .data4 = .{ 0x91, 0x94, 0x38, 0x02, 0x1f, 0x35, 0x78, 0xea } };
const iid_ExpandCollapsePattern: w.GUID = .{ .data1 = 0x619be086, .data2 = 0x1f4e, .data3 = 0x4ee4, .data4 = .{ 0xba, 0xfa, 0x21, 0x01, 0x28, 0x73, 0x87, 0x30 } };
const iid_ValuePattern: w.GUID = .{ .data1 = 0xa94cd8b1, .data2 = 0x0844, .data3 = 0x4cd6, .data4 = .{ 0x9d, 0x2d, 0x64, 0x05, 0x37, 0xab, 0x39, 0xe9 } };

// The slots this file calls, per interface. IUnknown's three come first in every one.
const slot_release = 2;
const automation_element_from_handle = 6;
const automation_control_view_walker = 14;
const walker_first_child = 4;
const walker_next_sibling = 6;
const element_current_pattern_as = 14;
const element_control_type = 21;
const element_name = 23;
const element_bounding_rectangle = 43;
const invoke_invoke = 3;
const toggle_toggle = 3;
const selection_item_select = 3;
const expand_collapse_expand = 3;
const expand_collapse_collapse = 4;
const expand_collapse_state = 5;
const value_set_value = 3;
const value_current_value = 4;

const Pattern = struct { id: i32, iid: *const w.GUID, name: []const u8 };

// The patterns an element's line lists, in UIA's own order of them.
const invoke_pattern: Pattern = .{ .id = 10000, .iid = &iid_InvokePattern, .name = "Invoke" };
const value_pattern: Pattern = .{ .id = 10002, .iid = &iid_ValuePattern, .name = "Value" };
const expand_collapse_pattern: Pattern = .{ .id = 10005, .iid = &iid_ExpandCollapsePattern, .name = "ExpandCollapse" };
const selection_item_pattern: Pattern = .{ .id = 10010, .iid = &iid_SelectionItemPattern, .name = "SelectionItem" };
const toggle_pattern: Pattern = .{ .id = 10015, .iid = &iid_TogglePattern, .name = "Toggle" };
const action_patterns = [_]Pattern{ invoke_pattern, expand_collapse_pattern, selection_item_pattern, toggle_pattern };

/// A COM object: what its pointer points at is its table of methods.
const Com = extern struct {
    methods: *const [64]?*const anyopaque,

    fn method(object: *Com, slot: usize, comptime F: type) F {
        return @ptrCast(@alignCast(object.methods[slot].?));
    }

    fn call0(object: *Com, slot: usize) HRESULT {
        return object.method(slot, *const fn (*Com) callconv(.winapi) HRESULT)(object);
    }

    /// One out-parameter: a pointer to whatever the slot writes.
    fn callOut(object: *Com, slot: usize, out: *anyopaque) HRESULT {
        return object.method(slot, *const fn (*Com, *anyopaque) callconv(.winapi) HRESULT)(object, out);
    }

    fn release(object: ?*Com) void {
        if (object) |o| _ = o.method(slot_release, *const fn (*Com) callconv(.winapi) u32)(o);
    }
};

const Failure = error{ComFailed};

fn failed(result: HRESULT) bool {
    return result < 0;
}

fn hresult(arena: std.mem.Allocator, result: HRESULT) []const u8 {
    return std.fmt.allocPrint(arena, "0x{X:0>8}", .{@as(u32, @bitCast(result))}) catch "?";
}

/// Reads and frees a BSTR the callee handed over.
fn bstr(arena: std.mem.Allocator, value: ?[*:0]u16) []const u8 {
    const v = value orelse return "";
    defer w.SysFreeString(v);
    return text.fromWide(arena, std.mem.span(v));
}

/// One request's UI Automation: the client object and the walker over the control view, the view
/// the C# agent's ControlViewWalker read. COM is started on the request's own thread — every
/// request on the serial port has one — and stopped with it.
const Automation = struct {
    client: *Com,
    walker: *Com,
    message: []const u8 = "",

    fn open(r: *const Request) union(enum) { ok: Automation, failure: []const u8 } {
        const started = w.CoInitializeEx(null, w.COINIT_MULTITHREADED);
        if (failed(started)) return .{ .failure = std.fmt.allocPrint(r.arena, "COM: {s}", .{hresult(r.arena, started)}) catch "COM" };
        var client: ?*anyopaque = null;
        const created = w.CoCreateInstance(&clsid_CUIAutomation, null, w.CLSCTX_INPROC_SERVER, &iid_IUIAutomation, &client);
        if (failed(created) or client == null) {
            w.CoUninitialize();
            return .{ .failure = std.fmt.allocPrint(r.arena, "UI Automation is not available ({s})", .{hresult(r.arena, created)}) catch "UI Automation is not available" };
        }
        const automation: *Com = @ptrCast(@alignCast(client.?));
        var walker: ?*Com = null;
        const got = automation.callOut(automation_control_view_walker, @ptrCast(&walker));
        if (failed(got) or walker == null) {
            Com.release(automation);
            w.CoUninitialize();
            return .{ .failure = std.fmt.allocPrint(r.arena, "no control view: {s}", .{hresult(r.arena, got)}) catch "no control view" };
        }
        return .{ .ok = .{ .client = automation, .walker = walker.? } };
    }

    fn close(a: *Automation) void {
        Com.release(a.walker);
        Com.release(a.client);
        w.CoUninitialize();
    }

    fn fromHandle(a: *Automation, r: *const Request, window: w.HWND) ?*Com {
        var element: ?*Com = null;
        const F = *const fn (*Com, w.HWND, *?*Com) callconv(.winapi) HRESULT;
        const result = a.client.method(automation_element_from_handle, F)(a.client, window, &element);
        if (failed(result)) {
            a.message = hresult(r.arena, result);
            return null;
        }
        if (element == null) a.message = std.fmt.allocPrint(r.arena, "no window {d}", .{@intFromPtr(window)}) catch "no window";
        return element;
    }

    /// An element's first child, or with a sibling slot its next one; null when there is none.
    fn step(a: *Automation, slot: usize, element: *Com) ?*Com {
        var next: ?*Com = null;
        const F = *const fn (*Com, *Com, *?*Com) callconv(.winapi) HRESULT;
        if (failed(a.walker.method(slot, F)(a.walker, element, &next))) return null;
        return next;
    }
};

/// The element's pattern, which the caller releases, or null.
fn patternOf(element: *Com, pattern: Pattern) ?*Com {
    var object: ?*Com = null;
    const F = *const fn (*Com, i32, *const w.GUID, *?*Com) callconv(.winapi) HRESULT;
    if (failed(element.method(element_current_pattern_as, F)(element, pattern.id, pattern.iid, &object))) return null;
    return object;
}

fn describe(r: *const Request, element: *Com, id: []const u8, depth: usize, origin: w.RECT) ![]const u8 {
    const arena = r.arena;
    var line: std.ArrayList(u8) = .empty;
    var kind: i32 = 0;
    const got_kind = element.callOut(element_control_type, @ptrCast(&kind));
    if (failed(got_kind)) return fail(r, got_kind);
    try line.appendNTimes(arena, ' ', depth);
    try line.print(arena, "{s} {s}", .{ id, text.controlTypeName(arena, kind) });
    var name: ?[*:0]u16 = null;
    const got_name = element.callOut(element_name, @ptrCast(&name));
    if (failed(got_name)) return fail(r, got_name);
    const title = bstr(arena, name);
    if (title.len > 0) try line.print(arena, " \"{s}\"", .{text.clip(arena, title)});
    if (patternOf(element, value_pattern)) |value| {
        defer Com.release(value);
        var current: ?[*:0]u16 = null;
        if (!failed(value.callOut(value_current_value, @ptrCast(&current)))) {
            const v = bstr(arena, current);
            if (v.len > 0) try line.print(arena, " value=\"{s}\"", .{text.clip(arena, v)});
        }
    }
    var box: w.RECT = .{};
    if (!failed(element.callOut(element_bounding_rectangle, @ptrCast(&box))) and
        (box.right > box.left or box.bottom > box.top))
    {
        try line.print(arena, " [{d},{d} {d}x{d}]", .{
            box.left -| origin.left, box.top -| origin.top, box.right -| box.left, box.bottom -| box.top,
        });
    }
    var actions: std.ArrayList([]const u8) = .empty;
    for (action_patterns) |pattern| if (patternOf(element, pattern)) |object| {
        try actions.append(arena, pattern.name);
        Com.release(object);
    };
    if (actions.items.len > 0) {
        try line.appendSlice(arena, " {");
        for (actions.items, 0..) |action, i| {
            if (i > 0) try line.append(arena, ',');
            try line.appendSlice(arena, action);
        }
        try line.append(arena, '}');
    }
    return line.items;
}

threadlocal var describe_error: []const u8 = "";

fn fail(r: *const Request, result: HRESULT) error{ComFailed} {
    describe_error = hresult(r.arena, result);
    return error.ComFailed;
}

/// The window a tree is read from: the one named, or the frontmost with a title — of the named
/// application, given one.
fn root(r: *const Request, app: []const u8, window: ?w.HWND) ?w.HWND {
    if (window) |handle| return handle;
    const Finder = struct {
        r: *const Request,
        app: []const u8,
        found: *?w.HWND,
        fn visit(self: @This(), candidate: w.HWND) bool {
            if (w.IsWindowVisible(candidate) == 0 or interface.title(self.r.arena, candidate).len == 0) return true;
            if (self.app.len > 0 and !std.ascii.eqlIgnoreCase(
                interface.processName(self.r.arena, interface.windowProcess(candidate)),
                self.app,
            )) return true;
            self.found.* = candidate;
            return false;
        }
    };
    var found: ?w.HWND = null;
    interface.eachWindow(Finder{ .r = r, .app = app, .found = &found }, Finder.visit);
    return found;
}

const limit = 2000;

const Walk = struct {
    r: *const Request,
    a: *Automation,
    origin: w.RECT,
    lines: std.ArrayList([]const u8) = .empty,

    fn walk(self: *Walk, element: *Com, id: []const u8, depth: usize) void {
        defer Com.release(element);
        if (self.lines.items.len >= limit or depth > 40) return;
        const arena = self.r.arena;
        // An element can fail on its own — a popup going away, or one that answers E_UNEXPECTED —
        // and that costs its own branch, never the rest of the tree.
        const line = describe(self.r, element, id, depth, self.origin) catch blk: {
            var unreadable: std.ArrayList(u8) = .empty;
            unreadable.appendNTimes(arena, ' ', depth) catch {};
            unreadable.print(arena, "{s} (unreadable: {s})", .{ id, describe_error }) catch {};
            break :blk unreadable.items;
        };
        self.lines.append(arena, line) catch return;
        var index: usize = 0;
        var child = self.a.step(walker_first_child, element);
        while (child) |c| : (index += 1) {
            if (self.lines.items.len >= limit) {
                Com.release(c);
                break;
            }
            // The sibling is found before the walk releases the child it is found from.
            const sibling = self.a.step(walker_next_sibling, c);
            self.walk(c, text.childId(arena, id, index), depth + 1);
            child = sibling;
        }
    }
};

pub fn tree(r: *const Request, app: []const u8, window: ?w.HWND) Answer {
    const top = root(r, app, window) orelse return r.failure("no such application has a window");
    var a = switch (Automation.open(r)) {
        .ok => |a| a,
        .failure => |message| return r.failure(message),
    };
    defer a.close();
    const element = a.fromHandle(r, top) orelse return r.failure(a.message);
    var origin: w.RECT = .{};
    if (window) |handle| origin = interface.windowRect(handle) orelse .{};
    var walk: Walk = .{ .r = r, .a = &a, .origin = origin };
    const root_id = std.fmt.allocPrint(r.arena, "{d}/", .{@intFromPtr(top)}) catch "0/";
    walk.walk(element, root_id, 0);
    if (walk.lines.items.len >= limit) {
        walk.lines.append(r.arena, std.fmt.allocPrint(r.arena, "… cut at {d} lines", .{limit}) catch "") catch {};
    }
    const joined = std.mem.join(r.arena, "\n", walk.lines.items) catch "";
    return r.answer(.{ .ok = true, .text = joined });
}

/// The element an id names, which the caller releases; null with `a.message` saying why.
fn find(r: *const Request, a: *Automation, id: []const u8) ?*Com {
    const missing = std.fmt.allocPrint(r.arena, "no element {s}", .{id}) catch "no element";
    const parsed = text.parseElementId(r.arena, id) orelse {
        a.message = missing;
        return null;
    };
    if (parsed.window == 0 or parsed.window > std.math.maxInt(usize)) {
        a.message = missing;
        return null;
    }
    var element = a.fromHandle(r, @ptrFromInt(@as(usize, @intCast(parsed.window)))) orelse return null;
    for (parsed.path) |wanted| {
        var child = a.step(walker_first_child, element);
        Com.release(element);
        var index = wanted;
        while (index > 0) : (index -= 1) {
            const c = child orelse break;
            const sibling = a.step(walker_next_sibling, c);
            Com.release(c);
            child = sibling;
        }
        element = child orelse {
            a.message = missing;
            return null;
        };
    }
    return element;
}

/// Runs `act` on the element an id names.
fn withElement(r: *const Request, id: []const u8, context: anytype, comptime act: fn (@TypeOf(context), *const Request, *Com) Answer) Answer {
    var a = switch (Automation.open(r)) {
        .ok => |a| a,
        .failure => |message| return r.failure(message),
    };
    defer a.close();
    const element = find(r, &a, id) orelse return r.failure(a.message);
    defer Com.release(element);
    return act(context, r, element);
}

/// Calls one method of one of the element's patterns, if it has that pattern.
fn perform(r: *const Request, element: *Com, pattern: Pattern, slot: usize) ?Answer {
    const object = patternOf(element, pattern) orelse return null;
    defer Com.release(object);
    const result = object.call0(slot);
    if (failed(result)) return r.failuref("{s} failed ({s})", .{ pattern.name, hresult(r.arena, result) });
    return r.ok();
}

pub fn press(r: *const Request, id: []const u8, requested: []const u8) Answer {
    const action = if (requested.len == 0) "Invoke" else requested;
    const Press = struct {
        fn act(name: []const u8, request: *const Request, element: *Com) Answer {
            const is = struct {
                fn eql(a: []const u8, b: []const u8) bool {
                    return std.mem.eql(u8, a, b);
                }
            }.eql;
            if (is(name, "Press") or is(name, "Invoke")) {
                if (perform(request, element, invoke_pattern, invoke_invoke)) |answer| return answer;
                if (perform(request, element, toggle_pattern, toggle_toggle)) |answer| return answer;
                if (perform(request, element, selection_item_pattern, selection_item_select)) |answer| return answer;
            } else if (is(name, "Toggle")) {
                if (perform(request, element, toggle_pattern, toggle_toggle)) |answer| return answer;
            } else if (is(name, "SelectionItem")) {
                if (perform(request, element, selection_item_pattern, selection_item_select)) |answer| return answer;
            } else if (is(name, "ExpandCollapse")) {
                if (patternOf(element, expand_collapse_pattern)) |object| {
                    defer Com.release(object);
                    var state: i32 = 0;
                    _ = object.callOut(expand_collapse_state, @ptrCast(&state));
                    const collapsed = 0;
                    const slot: usize = if (state == collapsed) expand_collapse_expand else expand_collapse_collapse;
                    const result = object.call0(slot);
                    if (failed(result)) return request.failuref("ExpandCollapse failed ({s})", .{hresult(request.arena, result)});
                    return request.ok();
                }
            }
            return request.failuref("that element does not take {s}", .{name});
        }
    };
    return withElement(r, id, action, Press.act);
}

pub fn set(r: *const Request, id: []const u8, value: []const u8) Answer {
    const Set = struct {
        fn act(v: []const u8, request: *const Request, element: *Com) Answer {
            const object = patternOf(element, value_pattern) orelse return request.failure("that element has no value to set");
            defer Com.release(object);
            if (std.mem.indexOfScalar(u8, v, 0) != null) return request.failure("the value holds a NUL");
            const units = std.unicode.utf8ToUtf16LeAllocZ(request.arena, v) catch return request.failure("the value holds a NUL");
            const string = w.SysAllocString(units.ptr);
            defer w.SysFreeString(string);
            const F = *const fn (*Com, ?[*:0]u16) callconv(.winapi) HRESULT;
            const result = object.method(value_set_value, F)(object, string);
            if (failed(result)) return request.failuref("setting the value failed ({s})", .{hresult(request.arena, result)});
            return request.ok();
        }
    };
    return withElement(r, id, value, Set.act);
}
