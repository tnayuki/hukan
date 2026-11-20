//! A GPU machine's Vulkan driver, for the root half: hukan's virtio-gpu speaks gfxstream, and the
//! guest reaches it through Mesa's gfxstream driver — a newer one than Ubuntu's, built by
//! Vendor/build-guest-gpu.sh and carried in this binary, so a new driver needs no template. The
//! guest's OpenGL is Ubuntu's own Zink on top of it, chosen for the device by a drirc rather than
//! anything set in a program's environment.
//!
//! Two builds, arm64 and x86_64: what Rosetta runs — Unity's editor — loads its own architecture's
//! Mesa and needs a driver of that architecture too. The manifest names the driver without a
//! directory, so each architecture's loader finds its own in its own library directory. Both are put
//! in place whether or not amd64 libraries are there yet: installed later, they find it waiting.
//!
//! Put in place at every start when they differ, on a machine with the device only: what a machine
//! without one has is left as Ubuntu made it. Ubuntu's own gfxstream manifest is diverted, so its
//! older driver does not answer for the same device beside this one — a diversion apt keeps across
//! upgrades.

const std = @import("std");
const Io = std.Io;
const agent = @import("../agent.zig");

const library = "libvulkan_gfxstream_hukan.so";
const drivers = [_]struct { directory: []const u8, data: []const u8 }{
    .{ .directory = "/usr/lib/aarch64-linux-gnu", .data = @embedFile("gpu/libvulkan_gfxstream-aarch64.so") },
    .{ .directory = "/usr/lib/x86_64-linux-gnu", .data = @embedFile("gpu/libvulkan_gfxstream-x86_64.so") },
};
const manifest_path = "/usr/share/vulkan/icd.d/hukan_gfxstream_icd.json";
const manifest = "{ \"file_format_version\": \"1.0.1\", \"ICD\": { \"library_path\": \"" ++
    library ++ "\", \"api_version\": \"1.4.0\" } }\n";
/// Zink for every virtio_gpu device: VZ's own screen has no render node, so it is the GPU's.
const drirc_path = "/usr/share/drirc.d/50-hukan-gpu.conf";
const drirc =
    \\<?xml version="1.0" standalone="yes"?>
    \\<driconf>
    \\    <device driver="loader" kernel_driver="virtio_gpu">
    \\        <application name="all">
    \\            <option name="dri_driver" value="zink" />
    \\        </application>
    \\    </device>
    \\</driconf>
    \\
;
const ubuntu_manifest = "/usr/share/vulkan/icd.d/gfxstream_vk_icd.json";

/// Whether hukan's virtio-gpu is there: a virtio device whose first feature bit, VIRGL — the 3D
/// one — is set (the file's first character), as the template's hukan-pin-gpu finds it.
fn present(io: Io) bool {
    var buffer: [64]u8 = undefined;
    var dir = Io.Dir.cwd().openDir(io, "/sys/bus/virtio/devices", .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        var path_buffer: [256]u8 = undefined;
        const device = std.fmt.bufPrint(&path_buffer, "/sys/bus/virtio/devices/{s}/device", .{entry.name}) catch continue;
        const id = Io.Dir.cwd().readFile(io, device, &buffer) catch continue;
        // virtio-gpu is device 16.
        if (!std.mem.eql(u8, std.mem.trim(u8, id, " \n"), "0x0010")) continue;
        const features = std.fmt.bufPrint(&path_buffer, "/sys/bus/virtio/devices/{s}/features", .{entry.name}) catch continue;
        const bits = Io.Dir.cwd().readFile(io, features, &buffer) catch continue;
        if (bits.len > 0 and bits[0] == '1') return true;
    }
    return false;
}

/// Writes `data` to `path` unless it is already there.
fn put(io: Io, path: []const u8, data: []const u8) void {
    const cwd = Io.Dir.cwd();
    const existing = std.heap.page_allocator.alloc(u8, data.len + 1) catch return;
    defer std.heap.page_allocator.free(existing);
    if (cwd.readFile(io, path, existing)) |found| {
        if (std.mem.eql(u8, found, data)) return;
    } else |_| {}
    if (std.fs.path.dirname(path)) |directory| cwd.createDirPath(io, directory) catch return;
    cwd.writeFile(io, .{ .sub_path = path, .data = data }) catch return;
}

/// The root half, at start, off the start's own thread: the diversion waits on dpkg's lock, which
/// an apt run at boot may hold.
pub fn install(served: *const agent.Agent) void {
    const thread = std.Thread.spawn(.{}, installNow, .{served}) catch return;
    thread.detach();
}

fn installNow(served: *const agent.Agent) void {
    const io = served.io;
    if (!present(io)) return;
    for (drivers) |driver| {
        var path_buffer: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}/" ++ library, .{driver.directory}) catch continue;
        put(io, path, driver.data);
    }
    put(io, manifest_path, manifest);
    put(io, drirc_path, drirc);
    var arena_state: std.heap.ArenaAllocator = .init(served.gpa);
    defer arena_state.deinit();
    const line = std.fmt.allocPrint(arena_state.allocator(), "{f}", .{std.json.fmt(.{
        .op = "exec",
        .argv = [_][]const u8{
            "dpkg-divert", "--quiet",                    "--local", "--rename",
            "--divert",    ubuntu_manifest ++ ".ubuntu", "--add",   ubuntu_manifest,
        },
        .timeout = 300,
    }, .{})}) catch return;
    _ = served.handleLine(arena_state.allocator(), line);
}
