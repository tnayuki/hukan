//! A screenshot as PNG: 8-bit RGBA, each row filtered the way that leaves the least to compress,
//! deflated with zlib. The Linux and Windows agents take their pictures this way; macOS has
//! `screencapture`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Encodes `rgba` — `width` x `height` pixels, four bytes each, rows top to bottom — as a PNG.
pub fn encode(gpa: Allocator, width: u32, height: u32, rgba: []const u8) ![]u8 {
    std.debug.assert(rgba.len == @as(usize, width) * height * 4);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, no interlace
    try chunk(w, "IHDR", &header);

    // The filtered rows, then deflated into one IDAT.
    const stride = @as(usize, width) * 4;
    const filtered = try gpa.alloc(u8, (stride + 1) * height);
    defer gpa.free(filtered);
    var candidate: [3][]u8 = undefined;
    for (&candidate) |*c| c.* = try gpa.alloc(u8, stride);
    defer for (candidate) |c| gpa.free(c);
    for (0..height) |y| {
        const row = rgba[y * stride ..][0..stride];
        const above: ?[]const u8 = if (y > 0) rgba[(y - 1) * stride ..][0..stride] else null;
        const kind, const bytes = filterRow(row, above, &candidate);
        filtered[y * (stride + 1)] = kind;
        @memcpy(filtered[y * (stride + 1) + 1 ..][0..stride], bytes);
    }

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 << 10);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    var compressor = try flate.Compress.init(&compressed.writer, window, .zlib, .level_6);
    try compressor.writer.writeAll(filtered);
    try compressor.finish();
    try compressed.writer.flush();
    try chunk(w, "IDAT", compressed.written());

    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

/// The row as the filter that makes it smallest to compress sends it — by the usual measure, the
/// smallest sum of the filtered bytes read as signed — and which filter that was.
fn filterRow(row: []const u8, above: ?[]const u8, candidate: *[3][]u8) struct { u8, []const u8 } {
    // 1: Sub, the byte four to the left; 2: Up, the byte above; 0: None.
    for (row, 0..) |byte, i| {
        candidate[0][i] = byte -% (if (i >= 4) row[i - 4] else 0);
        candidate[1][i] = byte -% (if (above) |a| a[i] else 0);
    }
    var best: struct { u8, []const u8 } = .{ 0, row };
    var best_cost = cost(row);
    for ([_]u8{ 1, 2 }, 0..) |kind, index| {
        const c = cost(candidate[index]);
        if (c < best_cost) {
            best_cost = c;
            best = .{ kind, candidate[index] };
        }
    }
    return best;
}

fn cost(bytes: []const u8) u64 {
    var sum: u64 = 0;
    for (bytes) |b| sum += @abs(@as(i8, @bitCast(b)));
    return sum;
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "a picture comes back from its PNG pixel for pixel" {
    const gpa = std.testing.allocator;
    const width = 37;
    const height = 11;
    var rgba: [width * height * 4]u8 = undefined;
    for (0..height) |y| for (0..width) |x| {
        const i = (y * width + x) * 4;
        rgba[i..][0..4].* = .{ @intCast(x * 7 % 256), @intCast(y * 23 % 256), @intCast((x ^ y) % 256), 255 };
    };
    const encoded = try encode(gpa, width, height, &rgba);
    defer gpa.free(encoded);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);

    // Read the one IDAT back, inflate it and undo the filters.
    var at: usize = 8;
    var idat: []const u8 = &.{};
    while (at < encoded.len) {
        const length = std.mem.readInt(u32, encoded[at..][0..4], .big);
        const kind = encoded[at + 4 ..][0..4];
        const data = encoded[at + 8 ..][0..length];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        try std.testing.expectEqual(crc.final(), std.mem.readInt(u32, encoded[at + 8 + length ..][0..4], .big));
        if (std.mem.eql(u8, kind, "IDAT")) idat = data;
        at += 12 + length;
    }
    var input: std.Io.Reader = .fixed(idat);
    var window: [flate.max_window_len]u8 = undefined;
    var inflate: flate.Decompress = .init(&input, .zlib, &window);
    const raw = try inflate.reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(raw);
    const stride = width * 4;
    try std.testing.expectEqual((stride + 1) * height, raw.len);
    var picture: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        const kind = raw[y * (stride + 1)];
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..stride) |i| {
            const left: u8 = if (i >= 4) picture[y * stride + i - 4] else 0;
            const up: u8 = if (y > 0) picture[(y - 1) * stride + i] else 0;
            picture[y * stride + i] = switch (kind) {
                0 => row[i],
                1 => row[i] +% left,
                2 => row[i] +% up,
                else => return error.UnknownFilter,
            };
        }
    }
    try std.testing.expectEqualSlices(u8, &rgba, &picture);
}
