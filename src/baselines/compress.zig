//! Compression bits-per-byte via std.compress.flate (gzip container).

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// Returns bits-per-byte = (compressed_size_bytes * 8) / raw_size_bytes.
pub fn gzipBitsPerByte(alloc: Allocator, input: []const u8) !f64 {
    if (input.len == 0) return 0.0;

    // Allocating writer with a non-trivial initial capacity so flate.Compress's
    // `output.buffer.len > 8` assertion is satisfied.
    var out: std.Io.Writer.Allocating = try .initCapacity(alloc, 4096);
    defer out.deinit();

    const window = try alloc.alloc(u8, flate.max_window_len);
    defer alloc.free(window);

    var c = try flate.Compress.init(&out.writer, window, .gzip, flate.Compress.Options.level_9);
    try c.writer.writeAll(input);
    try c.writer.flush();
    try out.writer.flush();

    const raw_f: f64 = @floatFromInt(input.len);
    const comp_f: f64 = @floatFromInt(out.written().len);
    return comp_f * 8.0 / raw_f;
}

test "uniform string compresses well" {
    var buf: [10000]u8 = undefined;
    @memset(&buf, 'a');
    const bpc = try gzipBitsPerByte(std.testing.allocator, &buf);
    try std.testing.expect(bpc < 0.05);
}

test "random string compresses poorly" {
    var prng = std.Random.DefaultPrng.init(0);
    const r = prng.random();
    var buf: [10000]u8 = undefined;
    for (&buf) |*c| c.* = 'a' + r.intRangeAtMost(u8, 0, 25);
    const bpc = try gzipBitsPerByte(std.testing.allocator, &buf);
    try std.testing.expect(bpc > 4.0);
}
