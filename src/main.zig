//! symbols CLI.
//!
//! Usage:
//!     symbols baselines --json data/raw/voynich/voynich.json
//!     symbols baselines --text-file path/to/file.txt
//!     symbols version

const std = @import("std");
const Io = std.Io;
const symbols = @import("symbols");

const Args = struct {
    cmd: enum { baselines, help, version } = .help,
    json_path: ?[]const u8 = null,
    text_path: ?[]const u8 = null,
};

fn parseArgs(argv: []const []const u8) !Args {
    var a: Args = .{};
    if (argv.len < 1) return a;
    const cmd = argv[0];
    if (std.mem.eql(u8, cmd, "baselines")) {
        a.cmd = .baselines;
    } else if (std.mem.eql(u8, cmd, "version")) {
        a.cmd = .version;
        return a;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help")) {
        a.cmd = .help;
        return a;
    } else {
        return error.UnknownCommand;
    }
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--json")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.json_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--text-file")) {
            i += 1;
            if (i >= argv.len) return error.MissingValue;
            a.text_path = argv[i];
        }
    }
    return a;
}

fn printHelp(w: *Io.Writer) !void {
    try w.print(
        \\symbols — Zig port of decipherment-research primitives
        \\
        \\Usage:
        \\  symbols baselines --json PATH        compute baselines on a Corpus JSON
        \\  symbols baselines --text-file PATH   compute baselines on a raw text file
        \\  symbols version                      print version
        \\
        \\Build: zig build
        \\Tests: zig build test
        \\
    , .{});
}

fn readAllToOwned(alloc: std.mem.Allocator, io: Io, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var allocating: Io.Writer.Allocating = .init(alloc);
    defer allocating.deinit();
    _ = try reader.interface.streamRemaining(&allocating.writer);
    return allocating.toOwnedSlice();
}

fn runBaselines(alloc: std.mem.Allocator, io: Io, w: *Io.Writer, args: Args) !void {
    var text: []u8 = undefined;
    var name: []const u8 = "(unknown)";
    var owns_text = false;
    var corpus_opt: ?symbols.corpus.Corpus = null;

    if (args.json_path) |p| {
        corpus_opt = try symbols.corpus.load(alloc, io, p);
        const c = &corpus_opt.?;
        text = try c.joinedChars("\n");
        name = c.name;
    } else if (args.text_path) |p| {
        text = try readAllToOwned(alloc, io, p);
        owns_text = true;
        name = p;
    } else {
        try w.print("error: pass --json PATH or --text-file PATH\n", .{});
        return error.NoInput;
    }
    defer if (corpus_opt) |*c| {
        var m = c.*;
        m.deinit();
    };
    defer if (owns_text) alloc.free(text);

    try w.print("== baselines: {s} ==\n", .{name});
    try w.print("  length          : {d} bytes\n", .{text.len});

    var alphabet_set: std.AutoHashMap(u8, void) = .init(alloc);
    defer alphabet_set.deinit();
    for (text) |c| _ = try alphabet_set.getOrPut(c);
    try w.print("  alphabet        : {d} symbols\n", .{alphabet_set.count()});

    const bpc = try symbols.compress.gzipBitsPerByte(alloc, text);
    try w.print("  gzip bits/byte  : {d:.4}\n", .{bpc});

    const tokens = try alloc.alloc([]const u8, text.len);
    defer alloc.free(tokens);
    for (text, 0..) |_, i| tokens[i] = text[i .. i + 1];

    const h1 = try symbols.entropy.shannonEntropy(alloc, tokens);
    const h1_mm = try symbols.entropy.shannonEntropyMM(alloc, tokens);
    const h2 = try symbols.entropy.conditionalEntropy(alloc, tokens, 1);
    const h2_mm = try symbols.entropy.conditionalEntropyMM(alloc, tokens, 1);
    const h3 = try symbols.entropy.conditionalEntropy(alloc, tokens, 2);
    const h3_mm = try symbols.entropy.conditionalEntropyMM(alloc, tokens, 2);
    try w.print("  H1 (plug-in)    : {d:.4} bits\n", .{h1});
    try w.print("  H1 (MM)         : {d:.4} bits\n", .{h1_mm});
    try w.print("  H2 (plug-in)    : {d:.4} bits\n", .{h2});
    try w.print("  H2 (MM)         : {d:.4} bits\n", .{h2_mm});
    try w.print("  H3 (plug-in)    : {d:.4} bits\n", .{h3});
    try w.print("  H3 (MM)         : {d:.4} bits\n", .{h3_mm});
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    const user_args = if (argv.len >= 1) argv[1..] else argv;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(init.io, &stdout_buffer);
    const w = &stdout_writer.interface;

    const args = parseArgs(user_args) catch |err| {
        try w.print("error: {s}\n", .{@errorName(err)});
        try printHelp(w);
        try w.flush();
        return err;
    };

    switch (args.cmd) {
        .help => try printHelp(w),
        .version => try w.print("symbols-zig 0.0.1\n", .{}),
        .baselines => try runBaselines(init.gpa, init.io, w, args),
    }
    try w.flush();
}
