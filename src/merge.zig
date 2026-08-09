//! Grafting the enrichment onto the extraction.
//!
//! Shared by `enrich`, which produces it, and by `images`, which amends it once
//! the local image paths are known.

const std = @import("std");
const model = @import("model.zig");

/// Leaky: the result borrows from both inputs and allocates its species array
/// in `arena`.
pub fn mergeLeaky(
    arena: std.mem.Allocator,
    dataset: model.Dataset,
    species: []const model.Species,
    enrichment: model.EnrichmentDataset,
) !model.EnrichedDataset {
    const merged = try arena.alloc(model.EnrichedSpecies, species.len);
    for (species, merged) |entry, *slot| {
        slot.* = .{
            .latin_name = entry.latin_name,
            .french_name = entry.french_name,
            .height_m = entry.height_m,
            .acidity = entry.acidity,
            .moisture = entry.moisture,
            .exposure = entry.exposure,
            .traits = entry.traits,
            .codes = entry.codes,
            .availability = entry.availability,
            .section = entry.section,
            .pdf_page = entry.pdf_page,
            .french_names = entry.french_names,
            .enrichment = enrichment.species.map.get(entry.latin_name) orelse
                std.debug.panic("no enrichment for {s}", .{entry.latin_name}),
        };
    }
    return .{
        .source = dataset.source,
        .legend = dataset.legend,
        .species_count = dataset.species_count,
        .species = merged,
        .references = enrichment.references,
        .licences = enrichment.licences,
        .coverage = enrichment.coverage,
    };
}
