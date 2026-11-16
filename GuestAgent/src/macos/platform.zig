//! What macOS adds to the shared agent: the screen (screen.zig), each request about it answered by
//! a fresh copy of this program.

const std = @import("std");
const agent = @import("../agent.zig");
const screen = @import("screen.zig");

pub const search_path = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// `--once <request>`: the one request a child was started for (screen.runInChild), answered on
/// stdout before anything listens. On the main thread, which is where `main` calls this and where
/// AppKit wants to be asked.
pub fn once(init: std.process.Init) void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const flag = args.next() orelse return;
    if (!std.mem.eql(u8, flag, "--once")) return;
    const body = args.next() orelse "";

    var arena_state: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    const arena = arena_state.allocator();
    const helper: agent.Agent = .{
        .mode = "user",
        .io = init.io,
        .gpa = std.heap.smp_allocator,
        .environ = init.environ_map,
        .search_path = search_path,
    };
    const answer = answerOnce(&helper, arena, body);
    const encoded = std.json.Stringify.valueAlloc(arena, std.json.Value{ .object = answer }, .{}) catch "";
    std.Io.File.stdout().writeStreamingAll(init.io, encoded) catch {};
    std.process.exit(0);
}

/// What a child answers to the request line it was given.
pub fn answerOnce(helper: *const agent.Agent, arena: std.mem.Allocator, body: []const u8) agent.Answer {
    var request: agent.Request = .{ .agent = helper, .arena = arena, .value = .null };
    request.value = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch
        return request.failure("malformed request");
    if (request.value != .object) return request.failure("malformed request");
    return screen.perform(&request);
}

pub fn startup(_: *const agent.Agent) void {}

pub fn extra(r: *agent.Request) ?agent.Answer {
    const op = r.text("op") orelse return null;
    if (!screen.handles(op)) return null;
    return screen.runInChild(r);
}
