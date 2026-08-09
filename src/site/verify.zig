//! The site's invariants. A breach is an error, not a warning.
//!
//! These are the obligations that come with other people's work: a licence we
//! are allowed to use, an author named wherever attribution is required, a
//! source URL on every description. Checking them at build time is what makes
//! them true of the published site rather than true of the documentation.

const std = @import("std");
const Allocator = std.mem.Allocator;
const licence_policy = @import("../licence.zig");
const model = @import("../model.zig");
const catalogue = @import("catalogue.zig");

pub const Finding = struct {
    subject: []const u8,
    problem: []const u8,
};

/// Leaky: findings are allocated in `arena`.
pub fn check(
    arena: Allocator,
    dataset: *const model.EnrichedDataset,
    entries: []const catalogue.Entry,
) ![]const Finding {
    var findings: std.ArrayList(Finding) = .empty;

    for (dataset.species) |species| {
        for (species.enrichment.images) |image| {
            if (!licence_policy.isAccepted(image.licence)) {
                try findings.append(arena, .{
                    .subject = species.latin_name,
                    .problem = try std.fmt.allocPrint(
                        arena,
                        "licence d'image non acceptée ({s})",
                        .{image.licence},
                    ),
                });
                continue;
            }
            const licence = dataset.licences.map.get(image.licence);
            const needs_author = if (licence) |present| present.attribution else true;
            if (needs_author and image.author.len == 0) {
                try findings.append(arena, .{
                    .subject = species.latin_name,
                    .problem = try std.fmt.allocPrint(
                        arena,
                        "image {s} sans auteur identifié",
                        .{image.licence},
                    ),
                });
            }
        }
        for (species.enrichment.descriptions) |description| {
            if (description.url.len == 0 or description.licence.len == 0) {
                try findings.append(arena, .{
                    .subject = species.latin_name,
                    .problem = "description sans URL ou sans licence",
                });
            }
        }
    }

    // The fold table in text.zig covers the Latin-1 Supplement and nothing
    // beyond it. Rather than let an unknown character fold to itself and
    // quietly break name deduplication, fail here and say so.
    for (entries) |entry| {
        for (entry.species.french_names) |name| {
            if (unfoldable(name)) |codepoint| {
                try findings.append(arena, .{
                    .subject = entry.species.latin_name,
                    .problem = try std.fmt.allocPrint(
                        arena,
                        "nom français contenant U+{X:0>4}, hors de la table de repli",
                        .{codepoint},
                    ),
                });
            }
        }
    }

    return findings.items;
}

/// The first codepoint outside what `text.fold` knows how to handle, if any.
fn unfoldable(name: []const u8) ?u21 {
    var codepoints = (std.unicode.Utf8View.init(name) catch return 0xFFFD).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        const known = codepoint < 0x80 or
            (codepoint >= 0x00C0 and codepoint <= 0x00FF) or
            (codepoint >= 0x0300 and codepoint <= 0x036F) or
            codepoint == 0x2019;
        if (!known) return codepoint;
    }
    return null;
}

const testing_gpa = std.testing.allocator;

test "a character outside the fold table is reported, not ignored" {
    try std.testing.expectEqual(@as(?u21, 0x0141), unfoldable("Łódź"));
    try std.testing.expectEqual(@as(?u21, null), unfoldable("Chêne pédonculé"));
    try std.testing.expectEqual(@as(?u21, null), unfoldable("L\u{2019}if"));
}
