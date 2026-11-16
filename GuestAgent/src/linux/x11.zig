//! A connection to the session's X server, over its unix socket, for one request of the host's:
//! opened, asked a few things in turn, and closed. Each request here is sent and its reply waited
//! for before the next, so the sequence numbers only ever have to be matched, never tracked.

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const keys = @import("keys.zig");

pub const Display = struct {
    fd: i32,
    arena: Allocator,
    io: std.Io,
    sequence: u16 = 0,
    root: u32,
    width: u16,
    height: u16,
    xtest: u8,
    keyboard: keys.Keyboard,
    /// The code of the X error the last failed request ended in.
    last_error: u8 = 0,

    pub const Opened = union(enum) { display: Display, failure: []const u8 };

    /// Reaches the session's X server: the display and authority the session gave systemd, or the
    /// first display and GDM's authority file when it has not given them yet.
    pub fn open(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map) Opened {
        const fail = struct {
            fn wayland(a: Allocator, why: []const u8) Opened {
                return .{ .failure = std.fmt.allocPrint(a, "no X11 display to reach ({s}) — the session may be on Wayland", .{why}) catch "out of memory" };
            }
        };
        const name = environ.get("DISPLAY") orelse ":0";
        const display_name = protocol.parseDisplay(if (name.len == 0) ":0" else name) orelse
            return fail.wayland(arena, std.fmt.allocPrint(arena, "bad display string: {s}", .{name}) catch "");
        const authority = blk: {
            if (environ.get("XAUTHORITY")) |path| if (path.len > 0) break :blk path;
            break :blk std.fmt.allocPrint(arena, "/run/user/{d}/gdm/Xauthority", .{linux.getuid()}) catch "";
        };

        const fd = connectSocket(display_name.number) catch |err|
            return fail.wayland(arena, std.fmt.allocPrint(arena, "dial unix /tmp/.X11-unix/X{d}: {t}", .{ display_name.number, err }) catch "");
        var d: Display = .{
            .fd = fd,
            .arena = arena,
            .io = io,
            .root = 0,
            .width = 0,
            .height = 0,
            .xtest = 0,
            .keyboard = .{ .min = 0, .per = 0, .keysyms = &.{} },
        };

        // No authority file, or no entry in it for this display, is a connection without one,
        // which a server allowing local users takes.
        const number_text = std.fmt.allocPrint(arena, "{d}", .{display_name.number}) catch "";
        const cookie = if (std.Io.Dir.cwd().readFileAlloc(io, authority, arena, .limited(1 << 20))) |file|
            protocol.findCookie(file, hostname(arena), number_text)
        else |_|
            null;
        d.writeAll(protocol.setup(arena, cookie)) catch |err| {
            d.close();
            return fail.wayland(arena, @errorName(err));
        };
        var head: [8]u8 = undefined;
        d.readExact(&head) catch |err| {
            d.close();
            return fail.wayland(arena, @errorName(err));
        };
        const rest = arena.alloc(u8, @as(usize, protocol.read(u16, &head, 6)) * 4) catch {
            d.close();
            return .{ .failure = "out of memory" };
        };
        d.readExact(rest) catch |err| {
            d.close();
            return fail.wayland(arena, @errorName(err));
        };
        const reply = std.mem.concat(arena, u8, &.{ &head, rest }) catch {
            d.close();
            return .{ .failure = "out of memory" };
        };
        const setup = protocol.parseSetup(reply, display_name.screen) catch |err| {
            d.close();
            const why = if (err == error.Refused)
                std.fmt.allocPrint(arena, "x protocol authentication refused: {s}", .{protocol.refusal(reply)}) catch ""
            else
                @errorName(err);
            return fail.wayland(arena, why);
        };
        d.root = setup.root;
        d.width = setup.width;
        d.height = setup.height;

        const extension = d.call(protocol.queryExtension(arena, "XTEST")) catch {
            d.close();
            return .{ .failure = "the X server has no XTEST" };
        };
        if (extension.len < 10 or extension[8] == 0) {
            d.close();
            return .{ .failure = "the X server has no XTEST" };
        }
        d.xtest = extension[9];

        const count: u8 = @intCast(@as(u16, setup.max_keycode) - setup.min_keycode + 1);
        const mapping = d.call(protocol.getKeyboardMapping(arena, setup.min_keycode, count)) catch |err| {
            d.close();
            return .{ .failure = d.describe(err) };
        };
        const words = (mapping.len - 32) / 4;
        const keysyms = arena.alloc(u32, words) catch {
            d.close();
            return .{ .failure = "out of memory" };
        };
        for (keysyms, 0..) |*k, i| k.* = protocol.read(u32, mapping, 32 + i * 4);
        d.keyboard = .{ .min = setup.min_keycode, .per = mapping[1], .keysyms = keysyms };
        return .{ .display = d };
    }

    pub fn close(d: *Display) void {
        if (d.fd >= 0) _ = linux.close(d.fd);
        d.fd = -1;
    }

    /// Says what a request's failure was, an X error by its name.
    pub fn describe(d: *const Display, err: anyerror) []const u8 {
        if (err == error.X) return protocol.errorName(d.last_error);
        return @errorName(err);
    }

    /// Sends a request that has no reply.
    pub fn send(d: *Display, request: []const u8) !void {
        try d.writeAll(request);
        d.sequence +%= 1;
    }

    /// Sends a request and waits for its reply, the whole of it.
    pub fn call(d: *Display, request: []const u8) ![]const u8 {
        try d.send(request);
        const wanted = d.sequence;
        while (true) {
            var head: [32]u8 = undefined;
            try d.readExact(&head);
            const sequence = protocol.read(u16, &head, 2);
            switch (head[0]) {
                0 => if (sequence == wanted) {
                    d.last_error = head[1];
                    return error.X;
                }, // an error for an earlier request with no reply
                1 => {
                    const extra = @as(usize, protocol.read(u32, &head, 4)) * 4;
                    const reply = try d.arena.alloc(u8, 32 + extra);
                    @memcpy(reply[0..32], &head);
                    try d.readExact(reply[32..]);
                    if (sequence == wanted) return reply;
                },
                // A generic event carries a length; every other event is the 32 bytes read.
                35 => {
                    const extra = @as(usize, protocol.read(u32, &head, 4)) * 4;
                    const skipped = try d.arena.alloc(u8, extra);
                    try d.readExact(skipped);
                },
                else => {},
            }
        }
    }

    /// Waits for the server to have taken every request sent, so an answer comes after its input.
    pub fn sync(d: *Display) !void {
        _ = try d.call(protocol.getInputFocus(d.arena));
    }

    fn writeAll(d: *Display, bytes: []const u8) !void {
        var rest = bytes;
        while (rest.len > 0) {
            const result = linux.write(d.fd, rest.ptr, rest.len);
            switch (linux.errno(result)) {
                .SUCCESS => rest = rest[result..],
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }

    fn readExact(d: *Display, buffer: []u8) !void {
        var filled: usize = 0;
        while (filled < buffer.len) {
            const result = linux.read(d.fd, buffer[filled..].ptr, buffer.len - filled);
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result == 0) return error.EndOfStream;
                    filled += result;
                },
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
    }
};

fn connectSocket(number: u32) !i32 {
    const result = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(result);
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    _ = std.fmt.bufPrint(&address.path, "/tmp/.X11-unix/X{d}", .{number}) catch unreachable;
    const connected = linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un));
    switch (linux.errno(connected)) {
        .SUCCESS => return fd,
        else => |e| {
            _ = linux.close(fd);
            return switch (e) {
                .NOENT => error.FileNotFound,
                .CONNREFUSED => error.ConnectionRefused,
                .ACCES => error.AccessDenied,
                else => error.ConnectFailed,
            };
        },
    }
}

/// This machine's name, which an authority entry for a local display is filed under.
fn hostname(arena: Allocator) []const u8 {
    var name: linux.utsname = undefined;
    if (linux.errno(linux.uname(&name)) != .SUCCESS) return "";
    return arena.dupe(u8, std.mem.sliceTo(&name.nodename, 0)) catch "";
}
