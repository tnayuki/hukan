//! The shared half of the agent, run here: what a request answers, and how answers share a stream.
//! Built for this Mac with libc, so a pipe can stand in for the host's end.

const std = @import("std");
const json = std.json;
const agent = @import("agent.zig");

const testing = std.testing;

var environ_map: std.process.Environ.Map = undefined;
var environ_ready = false;

fn makeAgent(extra: ?*const fn (*agent.Request) ?agent.Answer) agent.Agent {
    if (!environ_ready) {
        environ_map = std.process.Environ.Map.init(std.heap.smp_allocator);
        environ_map.put("PATH", "/usr/bin:/bin") catch unreachable;
        environ_ready = true;
    }
    return .{
        .mode = "user",
        .io = testing.io,
        .gpa = std.heap.smp_allocator,
        .environ = &environ_map,
        .search_path = "/usr/bin:/bin",
        .extra = extra,
    };
}

/// Answers one request line and hands back the answer as parsed JSON.
fn ask(a: *const agent.Agent, arena: std.mem.Allocator, line: []const u8) json.ObjectMap {
    const answer = a.handleLine(arena, line);
    const text = json.Stringify.valueAlloc(arena, json.Value{ .object = answer }, .{}) catch unreachable;
    const value = json.parseFromSliceLeaky(json.Value, arena, text, .{}) catch unreachable;
    return value.object;
}

fn decoded(arena: std.mem.Allocator, value: ?json.Value) []const u8 {
    const encoded = value.?.string;
    const out = arena.alloc(u8, std.base64.standard.Decoder.calcSizeForSlice(encoded) catch unreachable) catch unreachable;
    std.base64.standard.Decoder.decode(out, encoded) catch unreachable;
    return out;
}

test "ping says the mode" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    const answer = ask(&a, arena.allocator(), "{\"op\":\"ping\"}");
    try testing.expect(answer.get("ok").?.bool);
    try testing.expectEqualStrings("user", answer.get("mode").?.string);
    try testing.expectEqualStrings(agent.version, answer.get("version").?.string);
}

test "a malformed line is a failure, not nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    const answer = ask(&a, arena.allocator(), "not json");
    try testing.expect(!answer.get("ok").?.bool);
    try testing.expectEqualStrings("malformed request", answer.get("error").?.string);
}

test "exec carries stdin in and the exit and both outputs back" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    // "aGVsbG8=" is "hello"; sh is found on the agent's own PATH, not given as a path.
    const answer = ask(&a, arena.allocator(),
        \\{"op":"exec","argv":["sh","-c","cat; echo oops >&2; exit 3"],"stdin":"aGVsbG8="}
    );
    try testing.expect(answer.get("ok").?.bool);
    try testing.expectEqual(@as(i64, 3), answer.get("exit").?.integer);
    try testing.expectEqualStrings("hello", decoded(arena.allocator(), answer.get("stdout")));
    try testing.expectEqualStrings("oops\n", decoded(arena.allocator(), answer.get("stderr")));
    try testing.expect(!answer.get("timedOut").?.bool);
}

test "exec runs in the directory and environment it is given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    const answer = ask(&a, arena.allocator(),
        \\{"op":"exec","argv":["/bin/sh","-c","pwd; echo $HUKAN_TEST"],"cwd":"/tmp","env":{"HUKAN_TEST":"yes"}}
    );
    const out = decoded(arena.allocator(), answer.get("stdout"));
    try testing.expect(std.mem.endsWith(u8, out, "/tmp\nyes\n"));
}

test "exec answers when something it started is left running" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    const started = std.Io.Clock.Timestamp.now(testing.io, .awake);
    const answer = ask(&a, arena.allocator(),
        \\{"op":"exec","argv":["/bin/sh","-c","sleep 30 & echo started"]}
    );
    const took = started.durationTo(std.Io.Clock.Timestamp.now(testing.io, .awake)).raw.nanoseconds;
    try testing.expectEqualStrings("started\n", decoded(arena.allocator(), answer.get("stdout")));
    try testing.expectEqual(@as(i64, 0), answer.get("exit").?.integer);
    try testing.expect(took < 15 * std.time.ns_per_s);
}

test "exec times out, and stops what it started" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    const started = std.Io.Clock.Timestamp.now(testing.io, .awake);
    const answer = ask(&a, arena.allocator(),
        \\{"op":"exec","argv":["/bin/sh","-c","sleep 30; echo late"],"timeout":0.5}
    );
    const took = started.durationTo(std.Io.Clock.Timestamp.now(testing.io, .awake)).raw.nanoseconds;
    try testing.expect(answer.get("timedOut").?.bool);
    try testing.expectEqual(@as(i64, -1), answer.get("exit").?.integer);
    try testing.expectEqualStrings("", decoded(arena.allocator(), answer.get("stdout")));
    try testing.expect(took < 10 * std.time.ns_per_s);
}

test "exec says what it could not run" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    const answer = ask(&a, arena.allocator(), "{\"op\":\"exec\",\"argv\":[\"no-such-command-here\"]}");
    try testing.expect(!answer.get("ok").?.bool);
    try testing.expect(std.mem.startsWith(u8, answer.get("error").?.string, "cannot run no-such-command-here"));
    const empty = ask(&a, arena.allocator(), "{\"op\":\"exec\",\"argv\":[]}");
    try testing.expectEqualStrings("exec needs argv", empty.get("error").?.string);
}

test "write then read, with the mode given" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(null);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(testing.io, ".", arena.allocator());
    const path = try std.fs.path.join(arena.allocator(), &.{ base, "a", "b", "file.txt" });
    const write = try std.fmt.allocPrint(arena.allocator(),
        \\{{"op":"write","path":"{s}","data":"aGVsbG8=","mode":448}}
    , .{path});
    try testing.expect(ask(&a, arena.allocator(), write).get("ok").?.bool);
    const read = try std.fmt.allocPrint(arena.allocator(), "{{\"op\":\"read\",\"path\":\"{s}\"}}", .{path});
    try testing.expectEqualStrings("hello", decoded(arena.allocator(), ask(&a, arena.allocator(), read).get("data")));
    const stat = try std.Io.Dir.cwd().statFile(testing.io, path, .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o700), @backingInt(stat.permissions) & 0o777);
    const missing = ask(&a, arena.allocator(), "{\"op\":\"read\",\"path\":\"/no/such/file\"}");
    try testing.expect(!missing.get("ok").?.bool);
}

fn extraAnswersOnlyHello(r: *agent.Request) ?agent.Answer {
    const op = r.text("op") orelse return null;
    if (std.mem.eql(u8, op, "hello_there")) return r.answer(.{ .ok = true, .extra = true });
    return null;
}

test "an op the shared half does not know goes to the system's, then fails" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(&extraAnswersOnlyHello);
    try testing.expect(ask(&a, arena.allocator(), "{\"op\":\"hello_there\"}").get("extra").?.bool);
    try testing.expectEqualStrings("unknown op", ask(&a, arena.allocator(), "{\"op\":\"bogus\"}").get("error").?.string);
}

// MARK: Streams

const c = std.c;

fn pipeConnection(fds: *[2]c.fd_t) agent.Connection {
    return .{ .context = @ptrCast(fds), .readFn = pipeRead, .writeFn = pipeWrite };
}

fn pipeRead(context: *anyopaque, buffer: []u8) anyerror!usize {
    const fds: *[2]c.fd_t = @ptrCast(@alignCast(context));
    const n = c.read(fds[0], buffer.ptr, buffer.len);
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

fn pipeWrite(context: *anyopaque, data: []const u8) anyerror!usize {
    const fds: *[2]c.fd_t = @ptrCast(@alignCast(context));
    const n = c.write(fds[1], data.ptr, data.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

/// A stream the host reads, keeping every write in order and the size of the largest.
const Recorder = struct {
    mutex: std.Io.Mutex = .init,
    data: std.ArrayList(u8) = .empty,
    largest: usize = 0,
    /// When above zero, at most this many bytes are taken a write.
    shortcut: usize = 0,

    fn connection(r: *Recorder) agent.Connection {
        return .{ .context = r, .readFn = noRead, .writeFn = record };
    }

    fn noRead(_: *anyopaque, _: []u8) anyerror!usize {
        return 0;
    }

    fn record(context: *anyopaque, bytes: []const u8) anyerror!usize {
        const r: *Recorder = @ptrCast(@alignCast(context));
        r.mutex.lockUncancelable(testing.io);
        defer r.mutex.unlock(testing.io);
        const taken = if (r.shortcut > 0 and bytes.len > r.shortcut) bytes[0..r.shortcut] else bytes;
        r.largest = @max(r.largest, taken.len);
        try r.data.appendSlice(std.heap.smp_allocator, taken);
        return taken.len;
    }

    /// Every line so far, each of which has to be one message.
    fn lines(r: *Recorder, arena: std.mem.Allocator) ![]json.ObjectMap {
        r.mutex.lockUncancelable(testing.io);
        defer r.mutex.unlock(testing.io);
        var result: std.ArrayList(json.ObjectMap) = .empty;
        var it = std.mem.splitScalar(u8, r.data.items, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const value = try json.parseFromSliceLeaky(json.Value, arena, try arena.dupe(u8, line), .{});
            try result.append(arena, value.object);
        }
        return result.items;
    }

    fn wait(r: *Recorder, arena: std.mem.Allocator, count: usize) ![]json.ObjectMap {
        var tries: usize = 0;
        while (tries < 1000) : (tries += 1) {
            const got = try r.lines(arena);
            if (got.len >= count) return got;
            std.Io.sleep(testing.io, .fromMilliseconds(10), .awake) catch {};
        }
        return error.TimedOut;
    }

    fn deinit(r: *Recorder) void {
        r.data.deinit(std.heap.smp_allocator);
    }
};

var release_slow: std.atomic.Value(bool) = .init(false);

fn slowExtra(r: *agent.Request) ?agent.Answer {
    const op = r.text("op") orelse return null;
    if (!std.mem.eql(u8, op, "slow")) return null;
    while (!release_slow.load(.acquire)) std.Io.sleep(testing.io, .fromMilliseconds(5), .awake) catch {};
    return r.answer(.{ .ok = true, .slow = true });
}

fn serveInBackground(a: *const agent.Agent, input: agent.Connection, lines: *agent.Lines) !std.Thread {
    return std.Thread.spawn(.{}, agent.Agent.serveStream, .{ a, input, lines });
}

test "a stream carries each id back and runs requests side by side" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = makeAgent(&slowExtra);
    var fds: [2]c.fd_t = undefined;
    try testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
    var recorder: Recorder = .{};
    defer recorder.deinit();
    var lines: agent.Lines = .{ .connection = recorder.connection(), .io = testing.io, .chunk = 0 };
    const server = try serveInBackground(&a, pipeConnection(&fds), &lines);

    _ = try pipeWrite(&fds, "{\"id\":1,\"op\":\"slow\"}\n{\"id\":\"two\",\"op\":\"ping\"}\n");
    // The ping is answered while the slow request is still running.
    const first = try recorder.wait(arena.allocator(), 1);
    try testing.expectEqualStrings("two", first[0].get("id").?.string);
    try testing.expectEqualStrings("user", first[0].get("mode").?.string);
    release_slow.store(true, .release);
    const both = try recorder.wait(arena.allocator(), 2);
    try testing.expectEqual(@as(i64, 1), both[1].get("id").?.integer);
    try testing.expect(both[1].get("slow").?.bool);

    // A line that is no request is answered with no id, and the stream carries on.
    _ = try pipeWrite(&fds, "not json\n{\"id\":8,\"op\":\"ping\"}\n");
    const four = try recorder.wait(arena.allocator(), 4);
    var malformed: ?json.ObjectMap = null;
    var pinged = false;
    for (four[2..]) |answer| {
        if (answer.get("id").? == .null) malformed = answer;
        if (answer.get("id").? == .integer and answer.get("id").?.integer == 8) pinged = true;
    }
    try testing.expectEqualStrings("malformed request", malformed.?.get("error").?.string);
    try testing.expect(pinged);

    _ = c.close(fds[1]);
    server.join();
    _ = c.close(fds[0]);
}

fn sendBig(lines: *agent.Lines, i: usize) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const data = arena.allocator().alloc(u8, 3000 + i) catch unreachable;
    @memset(data, @intCast('a' + i % 26));
    var answer: agent.Answer = .empty;
    agent.put(&answer, arena.allocator(), "id", i);
    agent.put(&answer, arena.allocator(), "data", @as([]const u8, data));
    lines.send(arena.allocator(), answer);
}

test "lines stay whole when sent at once and in pieces" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var recorder: Recorder = .{ .shortcut = 5 }; // and the port takes less than it is given
    defer recorder.deinit();
    var lines: agent.Lines = .{ .connection = recorder.connection(), .io = testing.io, .chunk = 7 };
    const senders = 40;
    var threads: [senders]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, sendBig, .{ &lines, i });
    for (threads) |t| t.join();

    const got = try recorder.lines(arena.allocator());
    try testing.expectEqual(@as(usize, senders), got.len);
    var seen: [senders]bool = @splat(false);
    for (got) |message| {
        const id: usize = @intCast(message.get("id").?.integer);
        const data = message.get("data").?.string;
        try testing.expectEqual(3000 + id, data.len);
        for (data) |byte| try testing.expectEqual(@as(u8, @intCast('a' + id % 26)), byte);
        seen[id] = true;
    }
    for (seen) |s| try testing.expect(s);
    try testing.expect(recorder.largest <= 5);
}
