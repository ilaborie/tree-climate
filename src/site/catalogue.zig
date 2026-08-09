//! What every page and the search corpus need to know about a species, worked
//! out once instead of at each of the 358 call sites.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../model.zig");
const text = @import("../text.zig");

pub const Entry = struct {
    species: *const model.EnrichedSpecies,
    /// URL segment and image filename alike: one naming rule in the repository.
    slug: []const u8,
    primary_image: ?*const model.Image,
    /// The names worth searching, joined for display with " · ".
    searchable_names: []const u8,
    family: []const u8,
    family_fr: []const u8,
    french_description: []const u8,

    pub fn hasImage(self: Entry) bool {
        return self.primary_image != null;
    }
};

/// Leaky: everything is allocated in `arena` or borrows from `dataset`.
pub fn buildLeaky(arena: Allocator, dataset: *const model.EnrichedDataset) ![]Entry {
    const entries = try arena.alloc(Entry, dataset.species.len);
    for (dataset.species, entries) |*species, *entry| {
        const family = if (species.enrichment.taxon) |taxon| taxon.family else "";
        entry.* = .{
            .species = species,
            .slug = try text.slugAlloc(arena, species.latin_name),
            .primary_image = primaryImage(species),
            .searchable_names = try searchableNamesLeaky(arena, species),
            .family = family,
            .family_fr = try frenchFamilyLeaky(arena, family),
            .french_description = frenchDescription(species),
        };
    }
    return entries;
}

fn primaryImage(species: *const model.EnrichedSpecies) ?*const model.Image {
    for (species.enrichment.images) |*image| {
        if (image.primary) return image;
    }
    return null;
}

fn frenchDescription(species: *const model.EnrichedSpecies) []const u8 {
    for (species.enrichment.descriptions) |description| {
        if (std.mem.eql(u8, description.language, "fr")) return description.text;
    }
    return "";
}

/// Fagaceae becomes Fagacées. Francising a botanical family is regular, and all
/// 44 families in this corpus end in -aceae; without it, searching "Fagacées"
/// finds nothing.
pub fn frenchFamilyLeaky(arena: Allocator, family: []const u8) ![]const u8 {
    const suffix = "aceae";
    if (!std.mem.endsWith(u8, family, suffix)) return family;
    return std.mem.concat(arena, u8, &.{ family[0 .. family.len - suffix.len], "acées" });
}

/// The names from the PDF, plus Wikidata's vernacular name when it genuinely
/// adds a French variant.
///
/// Wikidata often serves the latin name as a "vernacular name" -- 202 species
/// out of 354 -- and letting that through would print
/// "Mûrier à papier hybride · Broussonetia kazinoki".
pub fn searchableNamesLeaky(
    arena: Allocator,
    species: *const model.EnrichedSpecies,
) ![]const u8 {
    const joined = try std.mem.join(arena, " · ", species.french_names);
    const vernacular = species.enrichment.wikidata_vernacular_name orelse return joined;

    const taxon = species.enrichment.taxon;
    const already: [4]?[]const u8 = .{
        species.latin_name,
        if (taxon) |present| present.canonical_name else null,
        if (taxon) |present| present.genus else null,
        if (taxon) |present| present.species else null,
    };
    const folded = try text.foldAlloc(arena, vernacular);
    for (already) |candidate| {
        if (candidate) |value| {
            const other = try text.foldAlloc(arena, value);
            if (std.mem.eql(u8, folded, other)) return joined;
        }
    }
    for (species.french_names) |name| {
        const other = try text.foldAlloc(arena, name);
        if (std.mem.eql(u8, folded, other)) return joined;
    }
    if (joined.len == 0) return arena.dupe(u8, vernacular);
    return std.mem.concat(arena, u8, &.{ joined, " · ", vernacular });
}

/// Species sharing a family, indexed by family name. Empty families are not
/// indexed: "unknown" is not a relationship.
pub const FamilyIndex = std.StringArrayHashMapUnmanaged(std.ArrayList(usize));

pub fn familyIndexLeaky(arena: Allocator, entries: []const Entry) !FamilyIndex {
    var index: FamilyIndex = .empty;
    for (entries, 0..) |entry, at| {
        if (entry.family.len == 0) continue;
        const slot = try index.getOrPut(arena, entry.family);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(arena, at);
    }
    return index;
}

const testing_gpa = std.testing.allocator;

test "family names are francised only when they end in -aceae" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][2][]const u8{
        .{ "Fagaceae", "Fagacées" },
        .{ "Rosaceae", "Rosacées" },
        // Not a suffix match: leave it alone rather than guess.
        .{ "Ginkgoaceae ", "Ginkgoaceae " },
        .{ "", "" },
    }) |case| {
        try std.testing.expectEqualStrings(case[1], try frenchFamilyLeaky(arena, case[0]));
    }
}
