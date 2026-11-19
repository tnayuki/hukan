//! Every test that runs on this Mac, in one build: the shared half, and of each system's half
//! what does not need that system — the macOS screen whole, Linux's key names, and
//! Windows' pure logic. Run by GuestAgent/test.sh, which links what the macOS half needs.

test {
    _ = @import("agent_test.zig");
    _ = @import("png.zig");
    _ = @import("macos/screen_test.zig");
    _ = @import("linux/keys.zig");
    _ = @import("windows/text.zig");
}
