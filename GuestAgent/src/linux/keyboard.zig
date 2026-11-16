//! The keys of a JIS Mac that Virtualization.framework's keyboard drops, for the root half: ¥ and
//! ろ reach the guest as no key at all, since the keyboard VZ gives a guest is ANSI whatever the
//! Mac's is. So they are typed on a keyboard of the agent's own, made with /dev/uinput, beside VZ's
//! — everything else still goes through VZ by position, and a Shift held there combines with a key
//! from here, the desktop reading both devices as one seat.
//!
//!   {"op":"jis_key","key":"yen"|"ro","down":true|false}  -> {"ok":true}
//!   {"op":"jis_key","key":"next_source"}                -> {"ok":true}
//!
//! 英数 and かな are not keys here but a choice of input source, which the host makes, and the next
//! source is GNOME's own Super+Space — typed on this keyboard, so it reaches a session on Wayland as
//! well as one on X11.

const std = @import("std");
const linux = std.os.linux;
const agent = @import("../agent.zig");

const ui_set_evbit: u32 = 0x40045564;
const ui_set_keybit: u32 = 0x40045565;
const ui_dev_setup: u32 = 0x405C5503;
const ui_dev_create: u32 = 0x5501;
const ev_syn: u16 = 0;
const ev_key: u16 = 1;

const key_yen: u16 = 124;
const key_ro: u16 = 89;
const key_left_meta: u16 = 125;
const key_space: u16 = 57;
/// Declared too, though nothing types it: udev calls a device a keyboard only when it has keys
/// among the first few dozen, and a device that is not one is not handed to the desktop.
const key_a: u16 = 30;

var lock: std.Io.Mutex = .init;
var device: ?i32 = null;

/// The device is made when the root half starts, not at the first key: the desktop picks a new
/// device up a beat after it appears, and a key typed into that beat would be lost.
pub fn startup(io: std.Io) void {
    const thread = std.Thread.spawn(.{}, makeAtStart, .{io}) catch return;
    thread.detach();
}

fn makeAtStart(io: std.Io) void {
    lock.lockUncancelable(io);
    defer lock.unlock(io);
    if (device == null) device = make() catch null;
}

pub fn answer(r: *agent.Request) agent.Answer {
    const io = r.agent.io;
    const name = r.text("key") orelse "";
    const next_source = std.mem.eql(u8, name, "next_source");
    const code: u16 = if (std.mem.eql(u8, name, "yen"))
        key_yen
    else if (std.mem.eql(u8, name, "ro"))
        key_ro
    else if (next_source)
        0
    else
        return r.failure("jis_key needs a key: yen, ro or next_source");
    const down = r.boolean("down") orelse false;

    lock.lockUncancelable(io);
    defer lock.unlock(io);
    const fd = device orelse blk: {
        const made = make() catch |err| return r.failure(describe(err));
        device = made;
        break :blk made;
    };
    const one = [_][2]i32{.{ code, @intFromBool(down) }};
    const switching = [_][2]i32{ .{ key_left_meta, 1 }, .{ key_space, 1 }, .{ key_space, 0 }, .{ key_left_meta, 0 } };
    const strokes: []const [2]i32 = if (next_source) &switching else &one;
    for (strokes, 0..) |stroke, i| {
        // A beat between strokes, as a hand leaves one: written back to back, the desktop took the
        // Space before it had taken the Super, and typed a space.
        if (i > 0) std.Io.sleep(io, .fromMilliseconds(30), .awake) catch {};
        emit(fd, ev_key, @intCast(stroke[0]), stroke[1]) catch |err| return r.failuref("write /dev/uinput: {t}", .{err});
        emit(fd, ev_syn, 0, 0) catch |err| return r.failuref("write /dev/uinput: {t}", .{err});
    }
    return r.ok();
}

const MakeError = error{ Open, EventBit, KeyBit, Setup, Create };

/// The error worded as the host has always been told it, less the system's own words for the reason.
fn describe(err: MakeError) []const u8 {
    return switch (err) {
        error.Open => "cannot open /dev/uinput",
        error.EventBit => "uinput event bit failed",
        error.KeyBit => "uinput key bit failed",
        error.Setup => "uinput setup failed",
        error.Create => "uinput create failed",
    };
}

fn make() MakeError!i32 {
    const opened = linux.open("/dev/uinput", .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Open;
    const fd: i32 = @intCast(opened);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ioctl(fd, ui_set_evbit, ev_key)) != .SUCCESS) return error.EventBit;
    for ([_]u16{ key_yen, key_ro, key_left_meta, key_space, key_a }) |code| {
        if (linux.errno(linux.ioctl(fd, ui_set_keybit, code)) != .SUCCESS) return error.KeyBit;
    }
    // struct uinput_setup: the input_id (bus, vendor, product, version), a name, ff_effects_max.
    var setup: [92]u8 = @splat(0);
    std.mem.writeInt(u16, setup[0..2], 0x06, .little); // BUS_VIRTUAL
    std.mem.writeInt(u16, setup[2..4], 0x1209, .little);
    std.mem.writeInt(u16, setup[4..6], 0x4B4E, .little);
    std.mem.writeInt(u16, setup[6..8], 1, .little);
    @memcpy(setup[8..][0.."hukan JIS keys".len], "hukan JIS keys");
    if (linux.errno(linux.ioctl(fd, ui_dev_setup, @intFromPtr(&setup))) != .SUCCESS) return error.Setup;
    if (linux.errno(linux.ioctl(fd, ui_dev_create, 0)) != .SUCCESS) return error.Create;
    return fd;
}

/// Writes one struct input_event: a timeval, then type, code and value.
fn emit(fd: i32, kind: u16, code: u16, value: i32) !void {
    var event: [24]u8 = undefined;
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &now);
    std.mem.writeInt(u64, event[0..8], @bitCast(@as(i64, now.sec)), .little);
    std.mem.writeInt(u64, event[8..16], @bitCast(@divTrunc(@as(i64, now.nsec), 1000)), .little);
    std.mem.writeInt(u16, event[16..18], kind, .little);
    std.mem.writeInt(u16, event[18..20], code, .little);
    std.mem.writeInt(u32, event[20..24], @bitCast(value), .little);
    const written = linux.write(fd, &event, event.len);
    if (linux.errno(written) != .SUCCESS) return error.WriteFailed;
    if (written != event.len) return error.ShortWrite;
}
