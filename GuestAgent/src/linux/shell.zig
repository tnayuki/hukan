//! The screen of a Linux guest, for the user half: what the host's screenshot, click, type, key and
//! window-list tools ask for, asked of hukan's GNOME Shell extension (shell/extension.js) over the
//! socket it opens in the user's runtime directory — on Wayland no client outside the compositor
//! may read or drive the screen, so the extension does it from inside.
//!
//!   {"op":"screenshot","window":?}                 -> {"ok":true,"data":"<base64 PNG>"}
//!   {"op":"windows"}                               -> {"ok":true,"text":"<id\tapp\ttitle\tx,y wxh a line>"}
//!   {"op":"click","x":..,"y":..,"count":?,"right":?,"window":?}  -> {"ok":true}
//!   {"op":"type","text":...}                       -> {"ok":true}
//!   {"op":"key","key":"return","modifiers":["command"]?}  -> {"ok":true}
//!
//! Positions are in the pixels of a screenshot — of that window's own, given a window.
//!
//! The extension travels inside this binary, so a new agent brings a new one: the root half puts it where GNOME looks for the
//! system's extensions (`install`), and the user half switches it on for the account (`enable`).
//! GNOME reads its extensions when it starts, so one put in place under a running desktop is there
//! from the next sign-in.

const std = @import("std");
const linux = std.os.linux;
const json = std.json;
const Io = std.Io;
const agent = @import("../agent.zig");
const keys = @import("keys.zig");

pub const uuid = "hukan-shell@hukan";
const directory = "/usr/share/gnome-shell/extensions/" ++ uuid;
const files = [_]struct { name: []const u8, data: []const u8 }{
    .{ .name = "metadata.json", .data = @embedFile("shell/metadata.json") },
    .{ .name = "extension.js", .data = @embedFile("shell/extension.js") },
};

/// The socket the extension listens on: there only while it runs.
fn socketPath(buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "/run/user/{d}/hukan-shell.sock", .{linux.getuid()}) catch "";
}

pub fn handles(op: []const u8) bool {
    for ([_][]const u8{ "screenshot", "windows", "click", "type", "key" }) |name| {
        if (std.mem.eql(u8, op, name)) return true;
    }
    return false;
}

/// Whether the extension is running in the signed-in desktop.
fn present() bool {
    var buffer: [64]u8 = undefined;
    const path = socketPath(&buffer);
    var z: [65]u8 = @splat(0);
    @memcpy(z[0..path.len], path);
    return linux.errno(linux.access(@ptrCast(&z), linux.F_OK)) == .SUCCESS;
}

/// The root half, at start: the extension's files where GNOME finds them, written only when they
/// differ, on a machine with a desktop.
pub fn install(io: Io) void {
    const cwd = Io.Dir.cwd();
    cwd.access(io, "/usr/bin/gnome-shell", .{}) catch return;
    var buffer: [64 << 10]u8 = undefined;
    for (files) |file| {
        var path_buffer: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, directory ++ "/{s}", .{file.name}) catch return;
        if (cwd.readFile(io, path, &buffer)) |existing| {
            if (std.mem.eql(u8, existing, file.data)) continue;
        } else |_| {}
        cwd.createDirPath(io, directory) catch return;
        cwd.writeFile(io, .{ .sub_path = path, .data = file.data }) catch return;
    }
}

/// The user half, at start: the extension added to the account's enabled ones unless it is there.
/// A running GNOME switches on one it found at its start the moment it is listed.
pub fn enable(served: *const agent.Agent) void {
    const thread = std.Thread.spawn(.{}, enableNow, .{served}) catch return;
    thread.detach();
}

fn enableNow(served: *const agent.Agent) void {
    const script =
        \\command -v gsettings >/dev/null || exit 0
        \\now=$(gsettings get org.gnome.shell enabled-extensions) || exit 0
        \\case "$now" in
        \\*"'
    ++ uuid ++
        \\'"*) exit 0 ;;
        \\"@as []") new="['
    ++ uuid ++
        \\']" ;;
        \\*) new="${now%]}, '
    ++ uuid ++
        \\']" ;;
        \\esac
        \\gsettings set org.gnome.shell enabled-extensions "$new"
    ;
    var arena_state: std.heap.ArenaAllocator = .init(served.gpa);
    defer arena_state.deinit();
    const line = std.fmt.allocPrint(arena_state.allocator(), "{f}", .{json.fmt(.{
        .op = "exec",
        .argv = [_][]const u8{ "/bin/sh", "-c", script },
        .timeout = 30,
    }, .{})}) catch return;
    _ = served.handleLine(arena_state.allocator(), line);
}

/// Answers a screen request through the extension. A key is turned into keysyms here, by the
/// names keys.zig reads.
pub fn answer(r: *agent.Request, op: []const u8) agent.Answer {
    if (!present())
        return r.failure("no desktop answers here: nobody is signed in, or hukan's GNOME Shell extension starts with the next sign-in");
    var request = r.value;
    if (std.mem.eql(u8, op, "key")) {
        var buffer: [64]u8 = undefined;
        const name = r.text("key") orelse "";
        const keysym = keys.keysymFor(&buffer, name) orelse return r.failuref("unknown key {s}", .{name});
        var keysyms: json.Array = .init(r.arena);
        if (r.field("modifiers")) |list| if (list == .array) {
            for (list.array.items) |item| {
                const modifier = if (item == .string) item.string else "";
                const held = keys.modifierKeysym(&buffer, modifier) orelse
                    return r.failuref("unknown modifier {s}", .{modifier});
                keysyms.append(.{ .integer = held }) catch return r.failure("out of memory");
            }
        };
        keysyms.append(.{ .integer = keysym }) catch return r.failure("out of memory");
        var object: json.ObjectMap = .empty;
        object.put(r.arena, "op", .{ .string = "keys" }) catch return r.failure("out of memory");
        object.put(r.arena, "keysyms", .{ .array = keysyms }) catch return r.failure("out of memory");
        request = .{ .object = object };
    }
    const line = json.Stringify.valueAlloc(r.arena, request, .{}) catch return r.failure("out of memory");
    const reply = ask(r.arena, line) catch |err|
        return r.failuref("the desktop's hukan extension did not answer: {t}", .{err});
    const parsed = json.parseFromSliceLeaky(json.Value, r.arena, reply, .{}) catch
        return r.failure("the desktop's hukan extension answered nonsense");
    if (parsed != .object) return r.failure("the desktop's hukan extension answered nonsense");
    return parsed.object;
}

/// One request to the extension and its answer, the whole of a connection.
fn ask(arena: std.mem.Allocator, line: []const u8) ![]const u8 {
    const opened = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    // A desktop that has stopped answering must not hold the request for good.
    const limit: linux.timeval = .{ .sec = 60, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&limit), @sizeOf(linux.timeval));
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = socketPath(&address.path);
    if (linux.errno(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS)
        return error.ConnectFailed;
    var rest = line;
    while (rest.len > 0) {
        const written = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(written)) {
            .SUCCESS => rest = rest[written..],
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
    _ = linux.write(fd, "\n", 1);
    var reply: std.ArrayList(u8) = .empty;
    var buffer: [64 << 10]u8 = undefined;
    while (true) {
        const count = linux.read(fd, &buffer, buffer.len);
        switch (linux.errno(count)) {
            .SUCCESS => {
                if (count == 0) break;
                try reply.appendSlice(arena, buffer[0..count]);
                if (std.mem.indexOfScalar(u8, buffer[0..count], '\n') != null) break;
            },
            .INTR => continue,
            .AGAIN => return error.Timeout,
            else => return error.ReadFailed,
        }
    }
    return std.mem.trimEnd(u8, reply.items, "\n");
}
