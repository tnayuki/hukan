//! The agent on Windows, reached over virtio-serial.
//!
//! It runs twice from one binary, like the macOS and Linux agents: as a service (--root, SYSTEM) for
//! what needs an administrator, and at logon in the user's session (--user), where a command has the
//! desktop. A service lives in session 0 and cannot see a desktop, so the interface has to be the
//! user half's.
//!
//! A serial port is one stream rather than a connection per request, so every request carries an
//! id and its answer carries it back, and requests run side by side (agent.serveStream). Besides
//! the shared requests:
//!
//!   {"id":5,"op":"display","width":1920,"height":1080}  -> {"id":5,"ok":true,"mode":"1920x1080"}
//!   {"id":6,"op":"await_exit","pid":1234}   -> {"id":6,"ok":true}, once that agent process has ended
//!
//! and the interface's requests (interface.zig). Unasked, every fifteen seconds:
//! {"hello":"user","version":"1","pid":1234}.
//!
//! The pid is there because the host cannot see the other end of a port close: the guest's driver
//! never tells QEMU, so a user half that ended with its logon still reads as connected. The root
//! half, which outlives every logon, is asked to wait on the user half's process instead, and the
//! host learns it has gone the moment Windows says so.

const std = @import("std");
const agent = @import("../agent.zig");
const interface = @import("interface.zig");
const w = @import("win32.zig");

var io: std.Io = undefined;
var environ: std.process.Environ.Map = undefined;

pub fn main(init: std.process.Init) void {
    // The user half is started by the Task Scheduler, which runs a task below normal priority, so a
    // build or an installer at normal priority filling the cores starved it and everything it ran
    // for minutes at a time. Above normal, each half answers whatever the guest is busy with; what
    // it runs goes back to normal, a child of an above-normal process starting at normal.
    _ = w.SetPriorityClass(w.GetCurrentProcess(), w.ABOVE_NORMAL_PRIORITY_CLASS);
    // Positions are the screen's pixels, not a scaled desktop's.
    _ = w.SetProcessDPIAware();
    io = init.io;
    environ = init.environ_map.clone(std.heap.smp_allocator) catch std.process.Environ.Map.init(std.heap.smp_allocator);

    var root = false;
    var worker = false;
    if (init.minimal.args.iterateAllocator(std.heap.smp_allocator)) |iterator| {
        var args = iterator;
        defer args.deinit();
        _ = args.next();
        while (args.next()) |argument| {
            root = root or std.mem.eql(u8, argument, "--root");
            worker = worker or std.mem.eql(u8, argument, worker_flag);
        }
    } else |_| {}
    if (root) {
        const table = [_]w.SERVICE_TABLE_ENTRYW{
            .{ .name = service_name, .main = serviceMain },
            .{ .name = null, .main = null },
        };
        _ = w.StartServiceCtrlDispatcherW(&table);
        return;
    }
    if (worker) run("user") else supervise();
}

// MARK: The user half's keeper

const worker_flag = "--worker";

/// What the Task Scheduler starts at logon keeps a copy of itself running, and serves nothing.
/// An agent that fails ends — Zig has no way back from a panic — and nothing would start the user
/// half again until the next logon: the Task Scheduler runs a task once, where the root half is a
/// service the service manager restarts. The copy says its own pid in its hello, so a failure
/// reads to the host as the user half going and a new one arriving, which is the road a new logon
/// already takes — what was waiting on it fails at once, and the drive is mapped again. A copy that
/// keeps failing is started less often, up to once a minute, so a broken agent does not spin.
fn supervise() void {
    const self = std.process.executablePathAlloc(io, std.heap.smp_allocator) catch {
        // Not knowing where this program is, there is no copy to start: serve instead.
        run("user");
        return;
    };
    var delay: i64 = 2;
    while (true) {
        const started = std.Io.Clock.Timestamp.now(io, .awake);
        if (std.process.spawn(io, .{
            .argv = &.{ self, "--user", worker_flag },
            .environ_map = &environ,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            .create_no_window = true,
        })) |spawned| {
            var child = spawned;
            _ = child.wait(io) catch {};
        } else |_| {}
        const lived = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toSeconds();
        delay = if (lived >= 60) 2 else @min(delay * 2, 60);
        std.Io.sleep(io, .fromSeconds(delay), .awake) catch {};
    }
}

// MARK: The service

const service_name = std.unicode.utf8ToUtf16LeStringLiteral("HukanGuestAgent");
var status_handle: ?*anyopaque = null;

fn report(state: w.DWORD, accepted: w.DWORD) void {
    var status: w.SERVICE_STATUS = .{ .current_state = state, .controls_accepted = accepted };
    if (status_handle) |handle| _ = w.SetServiceStatus(handle, &status);
}

fn serviceMain(_: w.DWORD, _: ?[*]?[*:0]u16) callconv(.winapi) void {
    status_handle = w.RegisterServiceCtrlHandlerExW(service_name, control, null);
    if (status_handle == null) return;
    report(w.SERVICE_START_PENDING, 0);
    const thread = std.Thread.spawn(.{}, run, .{"root"}) catch {
        report(w.SERVICE_STOPPED, 0);
        return;
    };
    thread.detach();
    report(w.SERVICE_RUNNING, w.SERVICE_ACCEPT_STOP | w.SERVICE_ACCEPT_SHUTDOWN);
}

/// Stop and shutdown end the service, which ends the process: the dispatcher returns once the
/// service says it has stopped, and so does `main`.
fn control(code: w.DWORD, _: w.DWORD, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) w.DWORD {
    switch (code) {
        w.SERVICE_CONTROL_STOP, w.SERVICE_CONTROL_SHUTDOWN => {
            report(w.SERVICE_STOP_PENDING, 0);
            report(w.SERVICE_STOPPED, 0);
        },
        w.SERVICE_CONTROL_INTERROGATE => {},
        else => {},
    }
    return w.NO_ERROR;
}

// MARK: The port

/// Serves the port for good: the host not being there yet, or the port going away, is tried again
/// shortly.
fn run(mode: []const u8) void {
    const served: agent.Agent = .{
        .mode = mode,
        .io = io,
        .gpa = std.heap.smp_allocator,
        .environ = &environ,
        // Empty: a bare name is found the way Windows finds it, on PATH with PATHEXT.
        .search_path = "",
        .extra = extra,
    };
    while (true) {
        if (Port.open(mode)) |port| port.serve(&served);
        std.Io.sleep(io, .fromSeconds(2), .awake) catch {};
    }
}

/// The virtio-serial port, opened overlapped: a read waits on it for as long as the host is quiet,
/// and a synchronous handle would hold every answer behind that read.
///
/// A port is never freed. An answer can still be on its way from a request's thread after the read
/// that started it has failed, and it must find a closed port rather than freed memory; a port is
/// opened once a logon, or once a host restarts, so what this keeps is a handful of bytes.
const Port = struct {
    handle: w.HANDLE,
    writing: std.Io.Mutex = .init,
    closed: std.atomic.Value(bool) = .init(false),
    lines: agent.Lines = undefined,

    fn open(mode: []const u8) ?*Port {
        var name_buffer: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "\\\\.\\Global\\dev.hukan.agent.{s}", .{mode}) catch return null;
        var wide: [64:0]u16 = undefined;
        const length = std.unicode.utf8ToUtf16Le(&wide, name) catch return null;
        wide[length] = 0;
        const handle = w.CreateFileW(wide[0..length :0], w.GENERIC_READ | w.GENERIC_WRITE, 0, null, w.OPEN_EXISTING, w.FILE_FLAG_OVERLAPPED, null);
        if (handle == w.invalid_handle) return null;
        const port = std.heap.smp_allocator.create(Port) catch {
            _ = w.CloseHandle(handle);
            return null;
        };
        port.* = .{ .handle = handle };
        // Pieces of 32 KiB: one write of a few megabytes never arrived at the host.
        port.lines = .{ .connection = port.connection(), .io = io, .chunk = 32 << 10 };
        return port;
    }

    fn close(port: *Port) void {
        port.closed.store(true, .release);
        port.writing.lockUncancelable(io);
        defer port.writing.unlock(io);
        _ = w.CloseHandle(port.handle);
        port.handle = w.invalid_handle;
    }

    /// Runs one read or write to its end.
    fn overlapped(port: *Port, comptime write: bool, buffer: []u8) !usize {
        const event = w.CreateEventW(null, 1, 0, null) orelse return error.NoEvent;
        defer _ = w.CloseHandle(event);
        var operation: w.OVERLAPPED = .{ .event = event };
        const count: w.DWORD = @intCast(@min(buffer.len, std.math.maxInt(w.DWORD)));
        const started = if (write)
            w.WriteFile(port.handle, buffer.ptr, count, null, &operation)
        else
            w.ReadFile(port.handle, buffer.ptr, count, null, &operation);
        if (started == 0 and w.GetLastError() != w.ERROR_IO_PENDING) return error.PortFailed;
        var done: w.DWORD = 0;
        if (w.GetOverlappedResult(port.handle, &operation, &done, 1) == 0) return error.PortFailed;
        return done;
    }

    fn connection(port: *Port) agent.Connection {
        return .{ .context = port, .readFn = read, .writeFn = writeFn };
    }

    fn read(context: *anyopaque, buffer: []u8) anyerror!usize {
        const port: *Port = @ptrCast(@alignCast(context));
        const count = try port.overlapped(false, buffer);
        if (count == 0) return error.PortEnded;
        return count;
    }

    /// One piece of a line; agent.Lines cuts the pieces and keeps the lines whole.
    fn writeFn(context: *anyopaque, data: []const u8) anyerror!usize {
        const port: *Port = @ptrCast(@alignCast(context));
        port.writing.lockUncancelable(io);
        defer port.writing.unlock(io);
        if (port.handle == w.invalid_handle) return error.PortClosed;
        return port.overlapped(true, @constCast(data));
    }

    fn serve(port: *Port, served: *const agent.Agent) void {
        const hello = std.Thread.spawn(.{}, helloForever, .{ port, served.mode }) catch null;
        served.serveStream(port.connection(), &port.lines);
        port.close();
        if (hello) |thread| thread.join();
    }

    fn helloForever(port: *Port, mode: []const u8) void {
        while (!port.closed.load(.acquire)) {
            var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            var message = agent.hello(arena_state.allocator(), mode);
            agent.put(&message, arena_state.allocator(), "pid", w.GetCurrentProcessId());
            port.lines.send(arena_state.allocator(), message);
            arena_state.deinit();
            // Fifteen seconds, in steps short enough that a closed port is noticed within one.
            var waited: usize = 0;
            while (waited < 60 and !port.closed.load(.acquire)) : (waited += 1) {
                std.Io.sleep(io, .fromMilliseconds(250), .awake) catch {};
            }
        }
    }
};

// MARK: What Windows adds

fn extra(r: *agent.Request) ?agent.Answer {
    const op = r.text("op") orelse return null;
    if (std.mem.eql(u8, op, "await_exit")) {
        const pid = r.number("pid") orelse return r.failure("await_exit needs a pid");
        if (pid < 0 or pid > std.math.maxInt(u32)) return r.ok();
        return awaitExit(r, @intFromFloat(pid));
    }
    if (std.mem.eql(u8, op, "display")) {
        const width = r.number("width");
        const height = r.number("height");
        if (width == null or height == null) return r.failure("display needs a width and a height");
        return setDisplay(r, clampDimension(width.?), clampDimension(height.?));
    }
    return interface.screen(r);
}

fn clampDimension(value: f64) u32 {
    return @intFromFloat(std.math.clamp(@trunc(value), 0, 65535));
}

/// Answers once the agent process with this pid has ended — at once if it already has, or if the
/// pid now belongs to something else, which is the same agent having ended.
fn awaitExit(r: *const agent.Request, pid: u32) agent.Answer {
    const process = w.OpenProcess(w.SYNCHRONIZE | w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return r.ok();
    defer _ = w.CloseHandle(process);
    if (std.ascii.eqlIgnoreCase(interface.processName(r.arena, pid), "hukan-guest-agent")) {
        _ = w.WaitForSingleObject(process, w.INFINITE);
    }
    return r.ok();
}

/// Puts the screen in a mode of exactly these pixels. The mode belongs to the session showing it,
/// so only the user half can set it.
fn setDisplay(r: *const agent.Request, width: u32, height: u32) agent.Answer {
    var mode: w.DEVMODEW = .{};
    if (w.EnumDisplaySettingsW(null, w.ENUM_CURRENT_SETTINGS, &mode) == 0) return r.failure("this session has no display");
    mode.pels_width = width;
    mode.pels_height = height;
    mode.fields = w.DM_PELSWIDTH | w.DM_PELSHEIGHT;
    if (w.ChangeDisplaySettingsW(&mode, w.CDS_UPDATEREGISTRY) == w.DISP_CHANGE_SUCCESSFUL) {
        return r.answer(.{ .ok = true, .mode = std.fmt.allocPrint(r.arena, "{d}x{d}", .{ width, height }) catch "" });
    }
    var offered: std.ArrayList([]const u8) = .empty;
    var index: w.DWORD = 0;
    while (true) : (index += 1) {
        var candidate: w.DEVMODEW = .{};
        if (w.EnumDisplaySettingsW(null, index, &candidate) == 0) break;
        const size = std.fmt.allocPrint(r.arena, "{d}x{d}", .{ candidate.pels_width, candidate.pels_height }) catch continue;
        for (offered.items) |seen| {
            if (std.mem.eql(u8, seen, size)) break;
        } else offered.append(r.arena, size) catch {};
    }
    std.mem.sort([]const u8, offered.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    const list = std.mem.join(r.arena, " ", offered.items) catch "";
    return r.failuref("the display has no {d}x{d}; it offers {s}", .{ width, height, list });
}
