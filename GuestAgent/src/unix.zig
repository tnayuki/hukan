//! The agent on macOS and Linux, reached over vsock.
//!
//! It runs twice in the guest, from one binary: in the logged-in user's session (`--user`, port
//! 7737) — where a command runs as the person would, with the desktop there — and as a system
//! service (`--root`, port 7738) for what needs an administrator. On macOS those are a LaunchAgent
//! and a LaunchDaemon, on Linux a systemd user service and a system one. Neither listens on the
//! network: vsock is a channel between the guest and the host running it, and a connection from
//! anywhere but the host (CID 2) is closed unanswered, so nothing inside the guest can borrow the
//! root half. What each system adds — the screen, and on Linux the JIS keys VZ drops — is in that
//! system's directory, behind `platform.extra`.

const std = @import("std");
const builtin = @import("builtin");
const agent = @import("agent.zig");

const platform = switch (builtin.os.tag) {
    .linux => @import("linux/platform.zig"),
    .macos => @import("macos/platform.zig"),
    else => unreachable,
};

const host_cid = 2;
const user_port = 7737;
const root_port = 7738;
const hello_port = 7739;
const cid_any = 0xffffffff;

pub fn main(init: std.process.Init) void {
    // A request run in a process of its own (macOS), answered before anything listens.
    platform.once(init);

    const io = init.io;
    const gpa = std.heap.smp_allocator;
    var args = init.minimal.args.iterate();
    _ = args.next();
    const root = if (args.next()) |arg| std.mem.eql(u8, arg, "--root") else false;
    const mode: []const u8 = if (root) "root" else "user";

    // What a login's PATH would be: a bare name is looked up the way a shell would look it up.
    var environ = init.environ_map.clone(gpa) catch fail("out of memory", .{});
    environ.put("PATH", platform.search_path) catch fail("out of memory", .{});
    const served: agent.Agent = .{
        .mode = mode,
        .io = io,
        .gpa = gpa,
        .environ = &environ,
        .search_path = platform.search_path,
        .extra = platform.extra,
    };
    platform.startup(&served);

    const listener = vsock.socket(io) catch |err| fail("socket: {t}", .{err});
    vsock.bind(listener, if (root) root_port else user_port) catch |err| fail("bind: {t}", .{err});
    vsock.listen(listener) catch |err| fail("listen: {t}", .{err});

    // The host is told this half is up rather than finding out by connecting: a connection to a
    // guest port nobody listens on has crashed Virtualization.framework in the host, so hukan only
    // dials an agent that has said it is there. Again every fifteen seconds, since a hukan that
    // restored the machine from a saved state did not hear the first one.
    if (std.Thread.spawn(.{}, announceForever, .{ io, mode })) |thread| thread.detach() else |_| {}

    while (true) {
        const accepted = vsock.accept(io, listener) catch |err| switch (err) {
            error.Interrupted, error.ConnectionAborted => continue,
            else => fail("accept: {t}", .{err}),
        };
        // The host and nothing else: a process in the guest connecting to its own vsock port must
        // not be handed a root shell.
        if (accepted.cid != host_cid) {
            vsock.close(accepted.fd);
            continue;
        }
        const thread = std.Thread.spawn(.{}, serveConnection, .{ &served, accepted.fd }) catch {
            vsock.close(accepted.fd);
            continue;
        };
        thread.detach();
    }
}

fn serveConnection(served: *const agent.Agent, fd: i32) void {
    defer vsock.close(fd);
    var context = fd;
    served.serve(vsock.connection(&context));
}

fn announceForever(io: std.Io, mode: []const u8) void {
    while (true) {
        announce(io, mode);
        std.Io.sleep(io, .fromSeconds(15), .awake) catch {};
    }
}

fn announce(io: std.Io, mode: []const u8) void {
    const fd = vsock.socket(io) catch return;
    defer vsock.close(fd);
    vsock.connect(fd, host_cid, hello_port) catch return;
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena_state.deinit();
    var context = fd;
    agent.respond(vsock.connection(&context), arena_state.allocator(), agent.hello(arena_state.allocator(), mode));
}

fn fail(comptime format: []const u8, values: anytype) noreturn {
    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "hukan-guest-agent: " ++ format ++ "\n", values) catch "hukan-guest-agent: failed\n";
    _ = vsock.write(2, message);
    std.process.exit(1);
}

/// vsock, by system call: Linux's own, or Darwin's through libc.
const vsock = switch (builtin.os.tag) {
    .linux => struct {
        const linux = std.os.linux;

        fn check(result: usize) !usize {
            return switch (linux.errno(result)) {
                .SUCCESS => result,
                .INTR => error.Interrupted,
                .CONNABORTED => error.ConnectionAborted,
                else => |e| {
                    _ = e;
                    return error.SystemCall;
                },
            };
        }

        fn socket(_: std.Io) !i32 {
            return @intCast(try check(linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0)));
        }

        fn bind(fd: i32, port: u32) !void {
            var address = linux.sockaddr.vm{ .port = port, .cid = cid_any, .flags = 0 };
            _ = try check(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.vm)));
        }

        fn listen(fd: i32) !void {
            _ = try check(linux.listen(fd, 16));
        }

        fn connect(fd: i32, cid: u32, port: u32) !void {
            var address = linux.sockaddr.vm{ .port = port, .cid = cid, .flags = 0 };
            _ = try check(linux.connect(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.vm)));
        }

        fn accept(_: std.Io, fd: i32) !struct { fd: i32, cid: u32 } {
            var peer: linux.sockaddr.vm = undefined;
            var length: linux.socklen_t = @sizeOf(linux.sockaddr.vm);
            const client: i32 = @intCast(try check(linux.accept4(fd, @ptrCast(&peer), &length, linux.SOCK.CLOEXEC)));
            return .{ .fd = client, .cid = peer.cid };
        }

        fn close(fd: i32) void {
            _ = linux.close(fd);
        }

        fn read(fd: i32, buffer: []u8) !usize {
            return check(linux.read(fd, buffer.ptr, buffer.len));
        }

        fn write(fd: i32, data: []const u8) usize {
            const result = linux.write(fd, data.ptr, data.len);
            return if (linux.errno(result) == .SUCCESS) result else 0;
        }

        fn connection(fd: *i32) agent.Connection {
            return .{ .context = fd, .readFn = readFn, .writeFn = writeFn };
        }

        fn readFn(context: *anyopaque, buffer: []u8) anyerror!usize {
            return read(@as(*i32, @ptrCast(@alignCast(context))).*, buffer);
        }

        fn writeFn(context: *anyopaque, data: []const u8) anyerror!usize {
            const written = write(@as(*i32, @ptrCast(@alignCast(context))).*, data);
            return if (written == 0) error.WriteFailed else written;
        }
    },
    .macos => struct {
        const c = std.c;

        const sockaddr_vm = extern struct {
            len: u8 = @sizeOf(sockaddr_vm),
            family: u8 = 40, // AF_VSOCK
            reserved1: u16 = 0,
            port: u32,
            cid: u32,
        };

        fn check(result: c_int) !c_int {
            if (result >= 0) return result;
            return switch (c.errno(result)) {
                .INTR => error.Interrupted,
                .CONNABORTED => error.ConnectionAborted,
                else => error.SystemCall,
            };
        }

        /// Darwin cannot open a socket already closed on exec, so the flag is set after, under
        /// the lock commands are started under: a command started for another request in between
        /// would otherwise inherit the socket.
        fn socket(io: std.Io) !i32 {
            agent.spawning.lockUncancelable(io);
            defer agent.spawning.unlock(io);
            const fd = try check(c.socket(40, c.SOCK.STREAM, 0));
            _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
            return fd;
        }

        fn bind(fd: i32, port: u32) !void {
            var address = sockaddr_vm{ .port = port, .cid = cid_any };
            _ = try check(c.bind(fd, @ptrCast(&address), @sizeOf(sockaddr_vm)));
        }

        fn listen(fd: i32) !void {
            _ = try check(c.listen(fd, 16));
        }

        fn connect(fd: i32, cid: u32, port: u32) !void {
            var address = sockaddr_vm{ .port = port, .cid = cid };
            _ = try check(c.connect(fd, @ptrCast(&address), @sizeOf(sockaddr_vm)));
        }

        /// The flag again, and the lock only once a connection is waiting: holding it through a
        /// blocking accept would stop every command from starting.
        fn accept(io: std.Io, fd: i32) !struct { fd: i32, cid: u32 } {
            while (true) {
                var ready = [_]c.pollfd{.{ .fd = fd, .events = c.POLL.IN, .revents = 0 }};
                if (c.poll(&ready, 1, -1) < 0) {
                    if (c.errno(@as(c_int, -1)) == .INTR) continue;
                    return error.SystemCall;
                }
                agent.spawning.lockUncancelable(io);
                defer agent.spawning.unlock(io);
                var peer: sockaddr_vm = undefined;
                var length: c.socklen_t = @sizeOf(sockaddr_vm);
                const client = try check(c.accept(fd, @ptrCast(&peer), &length));
                _ = c.fcntl(client, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
                return .{ .fd = client, .cid = peer.cid };
            }
        }

        fn close(fd: i32) void {
            _ = c.close(fd);
        }

        fn read(fd: i32, buffer: []u8) !usize {
            const n = c.read(fd, buffer.ptr, buffer.len);
            if (n < 0) return error.ReadFailed;
            return @intCast(n);
        }

        fn write(fd: i32, data: []const u8) usize {
            const n = c.write(fd, data.ptr, data.len);
            return if (n < 0) 0 else @intCast(n);
        }

        fn connection(fd: *i32) agent.Connection {
            return .{ .context = fd, .readFn = readFn, .writeFn = writeFn };
        }

        fn readFn(context: *anyopaque, buffer: []u8) anyerror!usize {
            return read(@as(*i32, @ptrCast(@alignCast(context))).*, buffer);
        }

        fn writeFn(context: *anyopaque, data: []const u8) anyerror!usize {
            const written = write(@as(*i32, @ptrCast(@alignCast(context))).*, data);
            return if (written == 0) error.WriteFailed else written;
        }
    },
    else => unreachable,
};
