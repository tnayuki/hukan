//! What Linux adds to the shared agent: the JIS keys VZ drops (keyboard.zig), for the root half,
//! and the screen over X11 (screen.zig), for the user half.

const std = @import("std");
const agent = @import("../agent.zig");
const screen = @import("screen.zig");
const keyboard = @import("keyboard.zig");

pub const search_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin";

/// Nothing to do on Linux: an X11 connection is opened per request, so a request about the screen
/// sees the screen as it is without a process of its own.
pub fn once(_: std.process.Init) void {}

pub fn startup(served: *const agent.Agent) void {
    if (std.mem.eql(u8, served.mode, "root")) keyboard.startup(served.io);
}

pub fn extra(r: *agent.Request) ?agent.Answer {
    const op = r.text("op") orelse return null;
    if (std.mem.eql(u8, op, "jis_key")) return keyboard.answer(r);
    if (screen.handles(op)) return screen.answer(r, op);
    return null;
}

test {
    _ = @import("protocol.zig");
    _ = @import("keys.zig");
}
