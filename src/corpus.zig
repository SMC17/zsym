//! Canonical Corpus types + JSON loader.
//!
//! The on-disk format matches what the Python `symbols` tool writes:
//!
//!     {
//!       "name": "voynich-eva-chars",
//!       "alphabet": [" ", "a", "c", ...],
//!       "meta": { ... },
//!       "documents": [
//!         { "id": "f1r", "section": "A", "meta": {...},
//!           "glyphs": [" ", "f", "a", "c", "h", ...] }
//!       ]
//!     }

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Document = struct {
    id: []u8,
    section: ?[]u8 = null,
    glyphs: [][]u8,

    pub fn len(self: Document) usize {
        return self.glyphs.len;
    }
};

pub const Corpus = struct {
    name: []u8,
    alphabet: [][]u8,
    documents: []Document,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
    }

    pub fn totalGlyphs(self: Corpus) usize {
        var n: usize = 0;
        for (self.documents) |d| n += d.glyphs.len;
        return n;
    }

    /// Concatenate all glyphs (char-level corpora produce a single string).
    /// Caller owns returned slice (allocated on the corpus arena).
    pub fn joinedChars(self: *Corpus, sep_between_docs: []const u8) ![]u8 {
        const alloc = self.arena.allocator();
        var total: usize = 0;
        for (self.documents, 0..) |d, i| {
            for (d.glyphs) |g| total += g.len;
            if (i + 1 < self.documents.len) total += sep_between_docs.len;
        }
        var out = try alloc.alloc(u8, total);
        var w: usize = 0;
        for (self.documents, 0..) |d, i| {
            for (d.glyphs) |g| {
                @memcpy(out[w .. w + g.len], g);
                w += g.len;
            }
            if (i + 1 < self.documents.len) {
                @memcpy(out[w .. w + sep_between_docs.len], sep_between_docs);
                w += sep_between_docs.len;
            }
        }
        return out;
    }
};

/// Load a Corpus from a JSON file path.
pub fn load(parent_alloc: Allocator, io: std.Io, path: []const u8) !Corpus {
    var arena = std.heap.ArenaAllocator.init(parent_alloc);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var allocating: std.Io.Writer.Allocating = .init(alloc);
    defer allocating.deinit();
    _ = try reader.interface.streamRemaining(&allocating.writer);
    const bytes = try allocating.toOwnedSlice();
    return loadFromBytes(arena, bytes);
}

/// Parse from an in-memory JSON buffer. Takes ownership of the arena.
pub fn loadFromBytes(arena: std.heap.ArenaAllocator, bytes: []const u8) !Corpus {
    var a = arena;
    errdefer a.deinit();
    const alloc = a.allocator();

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const root = parsed.value;

    if (root != .object) return error.InvalidCorpus;
    const obj = root.object;

    const name = obj.get("name") orelse return error.MissingName;
    if (name != .string) return error.InvalidName;
    const name_dup = try alloc.dupe(u8, name.string);

    const alphabet_val = obj.get("alphabet") orelse return error.MissingAlphabet;
    if (alphabet_val != .array) return error.InvalidAlphabet;
    const alphabet = try alloc.alloc([]u8, alphabet_val.array.items.len);
    for (alphabet_val.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidAlphabet;
        alphabet[i] = try alloc.dupe(u8, item.string);
    }

    const docs_val = obj.get("documents") orelse return error.MissingDocuments;
    if (docs_val != .array) return error.InvalidDocuments;
    const documents = try alloc.alloc(Document, docs_val.array.items.len);
    for (docs_val.array.items, 0..) |d, i| {
        if (d != .object) return error.InvalidDocument;
        const dobj = d.object;
        const did = dobj.get("id") orelse return error.MissingDocId;
        if (did != .string) return error.InvalidDocId;
        const glyphs_val = dobj.get("glyphs") orelse return error.MissingGlyphs;
        if (glyphs_val != .array) return error.InvalidGlyphs;
        const glyphs = try alloc.alloc([]u8, glyphs_val.array.items.len);
        for (glyphs_val.array.items, 0..) |g, j| {
            if (g != .string) return error.InvalidGlyph;
            glyphs[j] = try alloc.dupe(u8, g.string);
        }
        var section: ?[]u8 = null;
        if (dobj.get("section")) |s| {
            if (s == .string) section = try alloc.dupe(u8, s.string);
        }
        documents[i] = .{
            .id = try alloc.dupe(u8, did.string),
            .section = section,
            .glyphs = glyphs,
        };
    }

    return Corpus{
        .name = name_dup,
        .alphabet = alphabet,
        .documents = documents,
        .arena = a,
    };
}

test "load minimal corpus" {
    const json =
        \\{
        \\  "name": "test",
        \\  "alphabet": ["a", "b"],
        \\  "meta": {},
        \\  "documents": [
        \\    {"id": "d0", "section": null, "meta": {}, "glyphs": ["a", "b", "a"]},
        \\    {"id": "d1", "section": "X", "meta": {}, "glyphs": ["b"]}
        \\  ]
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const bytes = try arena.allocator().dupe(u8, json);
    var c = try loadFromBytes(arena, bytes);
    defer c.deinit();
    try std.testing.expectEqualStrings("test", c.name);
    try std.testing.expectEqual(@as(usize, 2), c.documents.len);
    try std.testing.expectEqual(@as(usize, 4), c.totalGlyphs());
    try std.testing.expectEqualStrings("X", c.documents[1].section.?);
}
