//! What every hukan guest agent says, whatever system it runs on: one JSON request a line, one JSON
//! answer a line. What a system adds is how it is reached — vsock on macOS and Linux, a serial port
//! on Windows — and the requests only it can answer (`Agent.extra`); this is the part that is the
//! same everywhere.
//!
//!   {"op":"ping"}                                  -> {"ok":true,"version":"1","mode":"user"}
//!   {"op":"exec","argv":[...],"cwd":?,"env":{}?,"stdin":"<base64>"?,"timeout":seconds?}
//!                                                  -> {"ok":true,"exit":0,"stdout":"<b64>","stderr":"<b64>","timedOut":false}
//!   {"op":"read","path":...}                       -> {"ok":true,"data":"<base64>"}
//!   {"op":"write","path":...,"data":"<b64>","mode":420?}  -> {"ok":true}
//!
//! A failure is {"ok":false,"error":"..."}.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;
const base64 = std.base64.standard;

/// What a ping answers. The host does not compare it — it compares the binary itself — so it only
/// has to change when someone reading a ping by hand needs to tell two apart.
pub const version = "1";

/// The most one request line may be: a file written whole, in base64, with room.
pub const max_request = 512 << 20;

/// An answer: a JSON object, built in the request's arena.
pub const Answer = json.ObjectMap;

/// Commands start one at a time under this, and so does every descriptor this process opens that a
/// command must not inherit: a system that cannot open one already closed on exec has to set the
/// flag after, and a fork in between would hand the child a connection to the host.
pub var spawning: Io.Mutex = .init;

pub const Agent = struct {
    mode: []const u8,
    io: Io,
    gpa: Allocator,
    /// The environment a command starts with, PATH included.
    environ: *const std.process.Environ.Map,
    /// The directories a bare command name is looked for in.
    search_path: []const u8,
    /// The requests a system adds; null for one it does not know.
    extra: ?*const fn (*Request) ?Answer = null,

    /// Answers one request line. The answer lives in `arena`.
    pub fn handleLine(agent: *const Agent, arena: Allocator, line: []const u8) Answer {
        var request: Request = .{ .agent = agent, .arena = arena, .value = .null };
        if (line.len > max_request) return request.failure("request too large");
        request.value = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch
            return request.failure("malformed request");
        if (request.value != .object) return request.failure("malformed request");
        return request.handle();
    }

    /// Reads one request from a connection, answers it, and returns.
    pub fn serve(agent: *const Agent, connection: Connection) void {
        var arena_state: std.heap.ArenaAllocator = .init(agent.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var line: std.ArrayList(u8) = .empty;
        var buffer: [64 << 10]u8 = undefined;
        reading: while (true) {
            const count = connection.read(&buffer) catch break;
            if (count == 0) break;
            for (buffer[0..count], 0..) |byte, i| if (byte == '\n') {
                line.appendSlice(arena, buffer[0..i]) catch return;
                break :reading;
            };
            line.appendSlice(arena, buffer[0..count]) catch return;
            if (line.items.len > max_request) break;
        }
        if (line.items.len == 0) return;
        const answer = agent.handleLine(arena, line.items);
        Lines.write(connection, arena, answer, 0) catch {};
    }

    /// Answers every request arriving on `connection` — one stream rather than a connection per
    /// request, so each request carries an id and its answer carries it back — each on a thread of
    /// its own, so a long one does not hold the rest. Returns when the stream ends.
    pub fn serveStream(agent: *const Agent, connection: Connection, lines: *Lines) void {
        var pending: std.ArrayList(u8) = .empty;
        defer pending.deinit(agent.gpa);
        var buffer: [64 << 10]u8 = undefined;
        while (true) {
            const count = connection.read(&buffer) catch return;
            if (count == 0) return;
            var start: usize = 0;
            for (buffer[0..count], 0..) |byte, i| if (byte == '\n') {
                pending.appendSlice(agent.gpa, buffer[start..i]) catch return;
                start = i + 1;
                const line = pending.toOwnedSlice(agent.gpa) catch return;
                const thread = std.Thread.spawn(.{}, answerOnStream, .{ agent, lines, line }) catch {
                    agent.gpa.free(line);
                    continue;
                };
                thread.detach();
            };
            pending.appendSlice(agent.gpa, buffer[start..count]) catch return;
        }
    }

    fn answerOnStream(agent: *const Agent, lines: *Lines, line: []u8) void {
        defer agent.gpa.free(line);
        var arena_state: std.heap.ArenaAllocator = .init(agent.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var answer = agent.handleLine(arena, line);
        // The id is whatever the request carried, the null of a line that was no request at all.
        var id: json.Value = .null;
        if (json.parseFromSliceLeaky(json.Value, arena, line, .{})) |value| {
            if (value == .object) id = value.object.get("id") orelse .null;
        } else |_| {}
        answer.put(arena, "id", id) catch {};
        lines.send(arena, answer);
    }
};

/// One end of a connection to the host, whatever carries it.
pub const Connection = struct {
    context: *anyopaque,
    readFn: *const fn (*anyopaque, []u8) anyerror!usize,
    writeFn: *const fn (*anyopaque, []const u8) anyerror!usize,

    pub fn read(c: Connection, buffer: []u8) anyerror!usize {
        return c.readFn(c.context, buffer);
    }

    pub fn write(c: Connection, data: []const u8) anyerror!usize {
        return c.writeFn(c.context, data);
    }
};

/// Writes answers to one stream a whole line at a time, from any number of threads at once: the
/// answers to requests running side by side must not end up inside each other.
pub const Lines = struct {
    connection: Connection,
    io: Io,
    /// At most this many bytes a write, when above zero: a serial port given a few megabytes in one
    /// write has lost them on the way to the host.
    chunk: usize,
    writing: Io.Mutex = .init,

    pub fn send(lines: *Lines, arena: Allocator, answer: Answer) void {
        lines.writing.lockUncancelable(lines.io);
        defer lines.writing.unlock(lines.io);
        write(lines.connection, arena, answer, lines.chunk) catch {};
    }

    fn write(connection: Connection, arena: Allocator, answer: Answer, chunk: usize) !void {
        var data: std.ArrayList(u8) = .empty;
        const encoded = json.Stringify.valueAlloc(arena, json.Value{ .object = answer }, .{}) catch
            try arena.dupe(u8, "{\"ok\":false,\"error\":\"the answer could not be encoded\"}");
        try data.appendSlice(arena, encoded);
        try data.append(arena, '\n');
        var rest = data.items;
        while (rest.len > 0) {
            const piece = if (chunk > 0 and rest.len > chunk) rest[0..chunk] else rest;
            const written = try connection.write(piece);
            if (written == 0) return error.WriteFailed;
            rest = rest[written..];
        }
    }
};

/// Hello is what an agent says to the host when it comes up, and again every fifteen seconds.
pub fn hello(arena: Allocator, mode: []const u8) Answer {
    var answer: Answer = .empty;
    put(&answer, arena, "hello", mode);
    put(&answer, arena, "version", version);
    return answer;
}

/// Writes one answer, as one line, to a connection that carries nothing else.
pub fn respond(connection: Connection, arena: Allocator, answer: Answer) void {
    Lines.write(connection, arena, answer, 0) catch {};
}

/// Sets a field of an answer from a Zig value: a string, a bool, an integer or a float.
pub fn put(answer: *Answer, arena: Allocator, key: []const u8, value: anytype) void {
    answer.put(arena, key, toValue(value)) catch {};
}

fn toValue(value: anytype) json.Value {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = value },
        .int, .comptime_int => .{ .integer = @intCast(value) },
        .float, .comptime_float => .{ .float = value },
        .null => .null,
        .pointer => .{ .string = value },
        else => if (T == json.Value) value else @compileError("no JSON for " ++ @typeName(T)),
    };
}

/// One request, and what it is answered with.
pub const Request = struct {
    agent: *const Agent,
    arena: Allocator,
    value: json.Value,

    pub fn field(r: *const Request, key: []const u8) ?json.Value {
        if (r.value != .object) return null;
        return r.value.object.get(key);
    }

    pub fn text(r: *const Request, key: []const u8) ?[]const u8 {
        const value = r.field(key) orelse return null;
        return if (value == .string) value.string else null;
    }

    pub fn boolean(r: *const Request, key: []const u8) ?bool {
        const value = r.field(key) orelse return null;
        return if (value == .bool) value.bool else null;
    }

    pub fn number(r: *const Request, key: []const u8) ?f64 {
        const value = r.field(key) orelse return null;
        return switch (value) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    /// A number that has to be whole.
    pub fn integer(r: *const Request, key: []const u8) ?i64 {
        const value = r.number(key) orelse return null;
        if (value != @trunc(value) or @abs(value) > 1 << 53) return null;
        return @intFromFloat(value);
    }

    /// An array of strings; null when it is not one, or holds anything else.
    pub fn strings(r: *const Request, key: []const u8) ?[]const []const u8 {
        const value = r.field(key) orelse return null;
        if (value != .array) return null;
        const list = r.arena.alloc([]const u8, value.array.items.len) catch return null;
        for (value.array.items, list) |item, *out| {
            if (item != .string) return null;
            out.* = item.string;
        }
        return list;
    }

    /// An answer made of the fields of a struct literal: `r.answer(.{ .ok = true, .exit = 0 })`.
    pub fn answer(r: *const Request, fields: anytype) Answer {
        var result: Answer = .empty;
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| {
            put(&result, r.arena, name, @field(fields, name));
        }
        return result;
    }

    pub fn ok(r: *const Request) Answer {
        return r.answer(.{ .ok = true });
    }

    pub fn failure(r: *const Request, message: []const u8) Answer {
        return r.answer(.{ .ok = false, .@"error" = message });
    }

    pub fn failuref(r: *const Request, comptime format: []const u8, values: anytype) Answer {
        const message = std.fmt.allocPrint(r.arena, format, values) catch "out of memory";
        return r.failure(message);
    }

    pub fn encode(r: *const Request, data: []const u8) []const u8 {
        const out = r.arena.alloc(u8, base64.Encoder.calcSize(data.len)) catch return "";
        return base64.Encoder.encode(out, data);
    }

    pub fn decode(r: *const Request, encoded: []const u8) ?[]u8 {
        const size = base64.Decoder.calcSizeForSlice(encoded) catch return null;
        const out = r.arena.alloc(u8, size) catch return null;
        base64.Decoder.decode(out, encoded) catch return null;
        return out;
    }

    fn handle(r: *Request) Answer {
        const op = r.text("op") orelse "";
        if (std.mem.eql(u8, op, "ping")) {
            return r.answer(.{ .ok = true, .version = version, .mode = r.agent.mode });
        } else if (std.mem.eql(u8, op, "exec")) {
            return execute(r);
        } else if (std.mem.eql(u8, op, "read")) {
            return readFile(r);
        } else if (std.mem.eql(u8, op, "write")) {
            return writeFile(r);
        }
        if (r.agent.extra) |extra| if (extra(r)) |answer_| return answer_;
        return r.failure("unknown op");
    }
};

fn readFile(r: *Request) Answer {
    const io = r.agent.io;
    const path = r.text("path") orelse "";
    if (path.len == 0) return r.failure("read needs a path");
    const data = Io.Dir.cwd().readFileAlloc(io, path, r.arena, .limited(max_request)) catch |err|
        return r.failuref("cannot read {s}: {t}", .{ path, err });
    return r.answer(.{ .ok = true, .data = r.encode(data) });
}

fn writeFile(r: *Request) Answer {
    const io = r.agent.io;
    const path = r.text("path") orelse "";
    const encoded = r.text("data");
    const data = if (encoded) |e| r.decode(e) else null;
    if (path.len == 0 or data == null) return r.failure("write needs a path and base64 data");
    if (std.fs.path.dirname(path)) |directory| {
        Io.Dir.cwd().createDirPath(io, directory) catch |err|
            return r.failuref("cannot make {s}: {t}", .{ directory, err });
    }
    const mode = r.integer("mode");
    const file = Io.Dir.cwd().createFile(io, path, .{ .permissions = permissions(mode orelse 0o644) }) catch |err|
        return r.failuref("cannot write {s}: {t}", .{ path, err });
    defer file.close(io);
    file.writeStreamingAll(io, data.?) catch |err| return r.failuref("cannot write {s}: {t}", .{ path, err });
    // Creating leaves the mode of a file that was already there alone.
    if (mode) |m| if (Io.File.Permissions.has_executable_bit) {
        file.setPermissions(io, permissions(m)) catch |err|
            return r.failuref("cannot set the mode of {s}: {t}", .{ path, err });
    };
    return r.ok();
}

fn permissions(mode: i64) Io.File.Permissions {
    if (builtin.os.tag == .windows) return .default_file;
    return @fromBackingInt(@as(std.posix.mode_t, @intCast(mode & 0o7777)));
}

/// The executable a bare command name stands for, looked up the way a shell would, on `search`.
fn lookPath(io: Io, arena: Allocator, name: []const u8, search: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, name, if (builtin.os.tag == .windows) "/\\" else "/") != null) return null;
    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';
    var directories = std.mem.splitScalar(u8, search, separator);
    while (directories.next()) |directory| {
        if (directory.len == 0) continue;
        const candidate = std.fs.path.join(arena, &.{ directory, name }) catch return null;
        Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return candidate;
    }
    return null;
}

fn execute(r: *Request) Answer {
    const io = r.agent.io;
    const argv = r.strings("argv") orelse return r.failure("exec needs argv of strings");
    if (argv.len == 0) return r.failure("exec needs argv");
    const timeout_seconds = blk: {
        const value = r.number("timeout") orelse 600;
        break :blk if (value > 0) value else 600;
    };

    var environ = r.agent.environ.clone(r.arena) catch return r.failure("out of memory");
    if (r.field("env")) |extra| if (extra == .object) {
        var it = extra.object.iterator();
        while (it.next()) |entry| if (entry.value_ptr.* == .string) {
            environ.put(entry.key_ptr.*, entry.value_ptr.string) catch {};
        };
    };
    const stdin: ?[]u8 = if (r.text("stdin")) |encoded|
        r.decode(encoded) orelse return r.failure("stdin is not base64")
    else
        null;
    const cwd: std.process.Child.Cwd = if (r.text("cwd")) |c| (if (c.len > 0) .{ .path = c } else .inherit) else .inherit;

    // A bare name is looked up on the agent's own PATH; std's own lookup would read the PATH the
    // agent was started with.
    const exe: std.process.ReplaceOptions.Exe = if (lookPath(io, r.arena, argv[0], r.agent.search_path)) |path|
        .{ .explicit = .{ .dir = .cwd(), .path = path } }
    else
        .detect;

    spawning.lockUncancelable(io);
    var child = std.process.spawn(io, .{
        .exe = exe,
        .argv = argv,
        .cwd = cwd,
        .environ_map = &environ,
        .stdin = if (stdin != null) .pipe else .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        // A group of its own, so a timeout stops what it started too rather than leaving a
        // shell's children behind.
        .pgid = if (builtin.os.tag == .windows) null else 0,
        .create_no_window = true,
    }) catch |err| {
        spawning.unlock(io);
        return r.failuref("cannot run {s}: {t}", .{ argv[0], err });
    };
    spawning.unlock(io);

    var feeding: ?std.Thread = null;
    if (stdin) |bytes| {
        const file = child.stdin.?;
        child.stdin = null;
        feeding = std.Thread.spawn(.{}, feed, .{ io, file, bytes }) catch blk: {
            file.close(io);
            break :blk null;
        };
    }

    var streams: Io.File.MultiReader.Buffer(2) = undefined;
    var reader: Io.File.MultiReader = undefined;
    reader.init(r.arena, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });

    const started = Io.Clock.Timestamp.now(io, .awake);
    const limit_ns: i96 = @intFromFloat(timeout_seconds * std.time.ns_per_s);
    var exited_at: ?Io.Clock.Timestamp = null;
    var timed_out = false;
    while (true) {
        if (reader.fill(64, .{ .duration = .{ .raw = .fromMilliseconds(100), .clock = .awake } })) |_| {
            continue;
        } else |err| switch (err) {
            error.Timeout => {},
            else => break, // every stream ended, or failed
        }
        const now = Io.Clock.Timestamp.now(io, .awake);
        if (exited_at == null and hasExited(&child)) exited_at = now;
        // The command is done but something it started still holds its output — `app &` — so
        // the output is what there was a beat later, and the exit is the command's.
        if (exited_at) |at| if (at.durationTo(now).raw.nanoseconds > 5 * std.time.ns_per_s) break;
        if (!timed_out and started.durationTo(now).raw.nanoseconds > limit_ns) {
            timed_out = true;
            stop(&child);
            if (exited_at == null) exited_at = now;
        }
    }
    const stdout = reader.toOwnedSlice(0) catch &.{};
    const stderr = reader.toOwnedSlice(1) catch &.{};
    reader.deinit();
    if (feeding) |thread| thread.join();

    const term = child.wait(io) catch null;
    // A command stopped for its time is -1 everywhere: on Windows what stops it leaves an exit
    // code of its own choosing, which would read as the command's.
    const exit: i64 = if (timed_out) -1 else if (term) |t| switch (t) {
        .exited => |code| code,
        else => -1,
    } else -1;
    return r.answer(.{
        .ok = true,
        .exit = exit,
        .stdout = r.encode(stdout),
        .stderr = r.encode(stderr),
        .timedOut = timed_out,
    });
}

fn feed(io: Io, file: Io.File, bytes: []const u8) void {
    file.writeStreamingAll(io, bytes) catch {};
    file.close(io);
}

/// Whether the command has ended, without reaping it: `wait` does that once the output is in.
fn hasExited(child: *const std.process.Child) bool {
    const id = child.id orelse return true;
    switch (builtin.os.tag) {
        .windows => {
            return windows.WaitForSingleObject(id, 0) == 0; // WAIT_OBJECT_0
        },
        .linux => {
            var info: [128]u8 = @splat(0);
            const flags = std.os.linux.W.EXITED | std.os.linux.W.NOHANG | std.os.linux.W.NOWAIT;
            const result = std.os.linux.waitid(.PID, id, @ptrCast(@alignCast(&info)), flags, null);
            if (std.os.linux.errno(result) != .SUCCESS) return true;
            return std.mem.readInt(i32, info[16..20], .little) != 0; // si_pid
        },
        else => {
            var info: [128]u8 align(8) = @splat(0);
            const p_pid = 1;
            const w_exited = 0x4;
            const w_nohang = 0x1;
            const w_nowait = 0x20;
            if (darwin.waitid(p_pid, @intCast(id), &info, w_exited | w_nohang | w_nowait) != 0) return true;
            return std.mem.readInt(i32, info[12..16], .little) != 0; // si_pid
        },
    }
}

/// What std does not declare for Windows in 0.17.
const windows = struct {
    extern "kernel32" fn WaitForSingleObject(handle: std.os.windows.HANDLE, milliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn TerminateProcess(process: std.os.windows.HANDLE, exit_code: u32) callconv(.winapi) c_int;
};

const darwin = struct {
    extern "c" fn waitid(idtype: c_int, id: c_uint, info: *anyopaque, options: c_int) c_int;
    extern "c" fn kill(pid: c_int, signal: c_int) c_int;
};

/// Stops a command and everything in its group.
fn stop(child: *const std.process.Child) void {
    const id = child.id orelse return;
    switch (builtin.os.tag) {
        .windows => _ = windows.TerminateProcess(id, 1),
        .linux => _ = std.os.linux.kill(-id, std.os.linux.SIG.KILL),
        else => _ = darwin.kill(-@as(c_int, @intCast(id)), 9),
    }
}
