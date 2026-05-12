//! symbols — Zig port of the decipherment-research primitives.
//!
//! Public surface:
//!     corpus   — Corpus / Document / Glyph types + JSON loader
//!     entropy  — Shannon + conditional entropy (plug-in and Miller-Madow)
//!     ngram    — Character n-gram language model with Laplace smoothing
//!     compress — bits-per-char via gzip (std.compress.gzip)
//!     pseudo   — matched-statistics pseudo-text generators
//!     subst    — monoalphabetic substitution cipher utilities
//!
//! All artifacts are JSON-serializable; the on-disk format is the cross-tool
//! interop contract with the Python `symbols` repo.

const std = @import("std");

pub const corpus = @import("corpus.zig");
pub const entropy = @import("baselines/entropy.zig");
pub const ngram = @import("baselines/ngram.zig");
pub const compress = @import("baselines/compress.zig");
pub const pseudo = @import("data/pseudo.zig");
pub const subst = @import("ciphers/substitution.zig");

test {
    _ = corpus;
    _ = entropy;
    _ = ngram;
    _ = compress;
    _ = pseudo;
    _ = subst;
}
