//! symbols — Zig port of the decipherment-research primitives.
//!
//! Public surface:
//!     corpus        — Corpus / Document / Glyph types + JSON loader
//!     entropy       — Shannon + conditional entropy (plug-in and Miller-Madow)
//!     ngram         — Character n-gram language model with Laplace smoothing
//!     compress      — bits-per-char via gzip (std.compress.gzip)
//!     pseudo        — matched-statistics pseudo-text generators
//!     subst         — monoalphabetic substitution cipher utilities
//!     residual_gap  — paired residual gzip-bpc gap with stationary-bootstrap
//!                     CIs (PR-A protocol; the methodology behind F7)
//!
//! All artifacts are JSON-serializable; the on-disk format is the cross-tool
//! interop contract with the Python `symbols` repo.

const std = @import("std");

pub const corpus = @import("corpus.zig");
pub const entropy = @import("baselines/entropy.zig");
pub const ngram = @import("baselines/ngram.zig");
pub const compress = @import("baselines/compress.zig");
pub const stationary_bootstrap = @import("baselines/stationary_bootstrap.zig");
pub const pseudo = @import("data/pseudo.zig");
pub const subst = @import("ciphers/substitution.zig");
pub const residual_gap = @import("methodology/residual_gap.zig");

test {
    _ = corpus;
    _ = entropy;
    _ = ngram;
    _ = compress;
    _ = stationary_bootstrap;
    _ = pseudo;
    _ = subst;
    _ = residual_gap;
}
