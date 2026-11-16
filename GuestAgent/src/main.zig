//! hukan-guest-agent: what hukan reaches a guest through. One program for the three systems a
//! machine can run; how the host is reached is each system's (unix.zig, windows/main.zig), and so
//! is what it adds to the shared requests (agent.zig).
//!
//! Built with the app by Vendor/build-guest-agents.sh; hukan puts it into a template while making
//! it, and replaces it at boot when it differs from the one it ships.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) void {
    switch (builtin.os.tag) {
        .windows => @import("windows/main.zig").main(init),
        .linux, .macos => @import("unix.zig").main(init),
        else => @compileError("hukan has no agent for this system"),
    }
}
