//! The data schema, and the only place it is written down.
//!
//! `std.json.Stringify` emits struct fields in declaration order, so the order
//! below *is* the key order of every file the pipeline writes. Changing it
//! changes the output; the round-trip golden test in tests/golden.zig catches
//! that immediately.
//!
//! Three fields are absent rather than null when they do not apply
//! (`Description.translated_from`, `Image.file`, `Image.local_file`). Since
//! `emit_null_optional_fields` is a whole-document option and every other
//! nullable field is spelled out as `null`, those two structs serialise
//! themselves. Everything else uses the default.

const std = @import("std");

/// Root of data/data.json — the extraction, before any enrichment.
pub const Dataset = struct {
    source: Source,
    legend: Legend,
    species_count: u32,
    species: []const Species,
};

/// Root of data/species-enriched.json — the extraction with enrichment grafted
/// onto each species. This is what Typst and the site generator read.
pub const EnrichedDataset = struct {
    source: Source,
    legend: Legend,
    species_count: u32,
    species: []const EnrichedSpecies,
    references: std.json.ArrayHashMap(Reference),
    licences: std.json.ArrayHashMap(Licence),
    coverage: Coverage,
};

/// Root of data/enrichment.json — the enrichment alone, keyed by latin name.
pub const EnrichmentDataset = struct {
    generated_on: []const u8,
    schema_version: u32,
    references: std.json.ArrayHashMap(Reference),
    licences: std.json.ArrayHashMap(Licence),
    coverage: Coverage,
    species: std.json.ArrayHashMap(Enrichment),
};

pub const Source = struct {
    title: []const u8,
    document: []const u8,
    publisher: []const u8,
    date: []const u8,
    file: []const u8,
    url: []const u8,
    reader_url: []const u8,
    pdf_pages: []const u8,
};

/// What the single-letter codes of the source table mean. The letters are the
/// field names because they are the data: `S` is Sec under moisture, Soleil
/// under exposure and Semi-persistant under traits, and only the column tells
/// them apart.
pub const Legend = struct {
    height_m: []const u8,
    acidity: struct { A: []const u8, N: []const u8, B: []const u8 },
    moisture: struct { H: []const u8, F: []const u8, S: []const u8 },
    exposure: struct { S: []const u8, M: []const u8, O: []const u8 },
    traits: struct { P: []const u8, S: []const u8, F: []const u8 },
    availability: struct { disponible: []const u8, peu_disponible: []const u8 },
};

/// The raw letter codes of one table row, null where the cell was empty.
pub const Codes = struct {
    acidity: ?[]const u8,
    moisture: ?[]const u8,
    exposure: ?[]const u8,
    traits: ?[]const u8,
};

pub const Species = struct {
    latin_name: []const u8,
    /// The French name cell verbatim; `french_names` is it split on commas.
    french_name: []const u8,
    height_m: ?u32,
    acidity: []const []const u8,
    moisture: []const []const u8,
    exposure: []const []const u8,
    traits: []const []const u8,
    codes: Codes,
    availability: []const u8,
    section: []const u8,
    pdf_page: u32,
    french_names: []const []const u8,
};

/// A `Species` with its `enrichment` appended. Declared separately rather than
/// with an optional field so that data/data.json cannot accidentally grow one.
pub const EnrichedSpecies = struct {
    latin_name: []const u8,
    french_name: []const u8,
    height_m: ?u32,
    acidity: []const []const u8,
    moisture: []const []const u8,
    exposure: []const []const u8,
    traits: []const []const u8,
    codes: Codes,
    availability: []const u8,
    section: []const u8,
    pdf_page: u32,
    french_names: []const []const u8,
    enrichment: Enrichment,
};

pub const Enrichment = struct {
    normalised_name: []const u8,
    estimated_rank: []const u8,
    taxon: ?Taxon,
    identifiers: std.json.ArrayHashMap([]const u8),
    wikidata_vernacular_name: ?[]const u8,
    descriptions: []const Description,
    images: []const Image,
    links: []const Link,
    /// Free-form French sentences saying the description or image describes a
    /// broader taxon than the row does. Never let one be dropped silently.
    warnings: []const []const u8,
};

pub const Taxon = struct {
    source: []const u8,
    queried_name: []const u8,
    gbif_key: u64,
    canonical_name: []const u8,
    scientific_name: []const u8,
    rank: []const u8,
    status: []const u8,
    confidence: u32,
    match_type: []const u8,
    kingdom: []const u8,
    class: []const u8,
    order: []const u8,
    family: []const u8,
    genus: []const u8,
    species: ?[]const u8,
    fallback_level: []const u8,
};

pub const Description = struct {
    language: []const u8,
    page_title: []const u8,
    text: []const u8,
    url: []const u8,
    source: []const u8,
    licence: []const u8,
    attribution: []const u8,
    scope: []const u8,
    /// Present on the 43 descriptions translated into French: the credit must
    /// point at the article that was actually translated.
    translated_from: ?TranslatedFrom = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        inline for (@typeInfo(@This()).@"struct".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "translated_from")) {
                if (self.translated_from) |origin| {
                    try jws.objectField(field.name);
                    try jws.write(origin);
                }
            } else {
                try jws.objectField(field.name);
                try jws.write(@field(self, field.name));
            }
        }
        try jws.endObject();
    }
};

pub const TranslatedFrom = struct {
    language: []const u8,
    page_title: []const u8,
    url: []const u8,
};

pub const Image = struct {
    source: []const u8,
    /// The Commons `File:` title. Absent on iNaturalist photos, which have no
    /// such thing.
    file: ?[]const u8 = null,
    url: []const u8,
    source_url: []const u8,
    width: u32,
    height: u32,
    author: []const u8,
    credit: []const u8,
    licence: []const u8,
    licence_url: []const u8,
    scope: []const u8,
    primary: bool,
    /// Repository-relative path, present once the image has been downloaded.
    /// Typst resolves it from the repository root.
    local_file: ?[]const u8 = null,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();
        inline for (@typeInfo(@This()).@"struct".fields) |field| {
            const value = @field(self, field.name);
            const omittable = comptime std.mem.eql(u8, field.name, "file") or
                std.mem.eql(u8, field.name, "local_file");
            if (omittable) {
                if (value) |present| {
                    try jws.objectField(field.name);
                    try jws.write(present);
                }
            } else {
                try jws.objectField(field.name);
                try jws.write(value);
            }
        }
        try jws.endObject();
    }
};

pub const Link = struct {
    label: []const u8,
    url: []const u8,
    publisher: []const u8,
};

pub const Reference = struct {
    name: []const u8,
    url: []const u8,
    licence: []const u8,
    usage: []const u8,
};

pub const Licence = struct {
    name: []const u8,
    url: []const u8,
    attribution: bool,
    share_alike: bool,
    commercial: bool,
};

pub const Coverage = struct {
    total: u32,
    with_description: u32,
    french_description: u32,
    with_image: u32,
    with_both: u32,
    with_neither: u32,
    taxon_resolved: u32,
    fallback_parent_species: u32,
    fallback_genus: u32,
    exact_match: u32,
};

/// img/credits.json: one entry per downloaded image, keyed by its filename.
pub const ImageCredit = struct {
    latin_name: []const u8,
    source: []const u8,
    licence: []const u8,
    licence_url: []const u8,
    author: []const u8,
    credit: []const u8,
    source_url: []const u8,
};
