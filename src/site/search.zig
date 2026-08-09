//! The search corpus: one JSON document per species, indexed in the browser.
//!
//! Field names here are the field names in web/src/search.js. Renaming one
//! without the other silently breaks search rather than failing the build,
//! which is why they are written next to each other in both files.

const std = @import("std");
const Writer = std.Io.Writer;
const catalogue = @import("catalogue.zig");
const Entry = catalogue.Entry;

const Document = struct {
    id: usize,
    slug: []const u8,
    latin_name: []const u8,
    french_names: []const u8,
    family: []const u8,
    family_fr: []const u8,
    text: []const u8,
    /// Whether a thumbnail exists, so the browser builds the same card the
    /// generator would have.
    image: bool,
    // Filter criteria: the same keys as the checkbox groups on the list page.
    acidity: []const []const u8,
    moisture: []const []const u8,
    exposure: []const []const u8,
    traits: []const []const u8,
    availability: []const u8,
};

fn document(entry: Entry, id: usize) Document {
    return .{
        .id = id,
        .slug = entry.slug,
        .latin_name = entry.species.latin_name,
        .french_names = entry.searchable_names,
        .family = entry.family,
        .family_fr = entry.family_fr,
        .text = entry.french_description,
        .image = entry.hasImage(),
        .acidity = entry.species.acidity,
        .moisture = entry.species.moisture,
        .exposure = entry.species.exposure,
        .traits = entry.species.traits,
        .availability = entry.species.availability,
    };
}

/// Written without whitespace: this file is downloaded by every visitor who
/// searches, and nothing reads it by eye.
pub fn write(out: *Writer, entries: []const Entry) !void {
    var stringify: std.json.Stringify = .{ .writer = out, .options = .{} };
    try stringify.beginArray();
    for (entries, 0..) |entry, id| try stringify.write(document(entry, id));
    try stringify.endArray();
    try out.writeByte('\n');
}

const testing_gpa = std.testing.allocator;

test "a corpus document carries exactly the fields search.js reads" {
    const model = @import("../model.zig");

    var species: model.EnrichedSpecies = undefined;
    species.latin_name = "Quercus robur";
    species.acidity = &.{"acide"};
    species.moisture = &.{"frais"};
    species.exposure = &.{"soleil"};
    species.traits = &.{};
    species.availability = "disponible";

    const entry: Entry = .{
        .species = &species,
        .slug = "quercus-robur",
        .primary_image = null,
        .searchable_names = "Chêne pédonculé",
        .family = "Fagaceae",
        .family_fr = "Fagacées",
        .french_description = "Un arbre.",
    };

    var out: Writer.Allocating = .init(testing_gpa);
    defer out.deinit();
    try write(&out.writer, &.{entry});

    try std.testing.expectEqualStrings(
        \\[{"id":0,"slug":"quercus-robur","latin_name":"Quercus robur",
    ++
        \\"french_names":"Chêne pédonculé","family":"Fagaceae","family_fr":"Fagacées",
    ++
        \\"text":"Un arbre.","image":false,"acidity":["acide"],"moisture":["frais"],
    ++
        \\"exposure":["soleil"],"traits":[],"availability":"disponible"}]
    ++ "\n", out.written());
}
