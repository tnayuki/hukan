//! What Linux adds to the shared agent: the JIS keys VZ drops (keyboard.zig), for the root half,
//! and the screen, through hukan's GNOME Shell extension (shell.zig), for the user half.

const std = @import("std");
const agent = @import("../agent.zig");
const keyboard = @import("keyboard.zig");
const shell = @import("shell.zig");

pub const search_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin";

/// Nothing to do on Linux: the screen is GNOME Shell's to answer for, asked per request.
pub fn once(_: std.process.Init) void {}

pub fn startup(served: *const agent.Agent) void {
    if (std.mem.eql(u8, served.mode, "root")) {
        keyboard.startup(served.io);
        shell.install(served.io);
    } else {
        shell.enable(served);
    }
}

pub fn extra(r: *agent.Request) ?agent.Answer {
    const op = r.text("op") orelse return null;
    if (std.mem.eql(u8, op, "jis_key")) return keyboard.answer(r);
    if (shell.handles(op)) return shell.answer(r, op);
    return null;
}

test {
    _ = @import("keys.zig");
    _ = @import("shell.zig");
}
