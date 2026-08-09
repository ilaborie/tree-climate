//! Tests that read the repository or shell out to an external binary.
//!
//! `zig build test-golden` runs them with the build root as the working
//! directory. They are kept out of `zig build test` so the inner development
//! loop stays free of filesystem latency.

const std = @import("std");
const tc = @import("tree_climate");

const io = std.testing.io;

// Guards the whole file: every other golden test resolves paths relative to
// the repository root, so if this one fails their failures are meaningless.
test "the working directory is the repository root" {
    const gpa = std.testing.allocator;

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, "data/data.json", gpa, .limited(4 << 20));
    defer gpa.free(bytes);

    try std.testing.expect(bytes.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), bytes[0]);
}

/// Parses `path` as `T` and re-serialises it, expecting the original bytes back.
///
/// This is the load-bearing test of the whole rewrite. Passing means the schema
/// in `model.zig` is complete (no field silently dropped), that key order is
/// determined by the model rather than by the input, and that the canonical
/// format matches what the pipeline has always written. Everything downstream
/// assumes all three.
fn expectRoundTrip(comptime T: type, path: []const u8, limit: usize) !void {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The parsed document borrows from these bytes, so they must outlive it.
    const original = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(limit));
    const document = try std.json.parseFromSliceLeaky(T, arena, original, .{});

    const rendered = try tc.json.stringifyAlloc(gpa, document);
    defer gpa.free(rendered);

    try expectIdentical(path, original, rendered);
}

/// `expectEqualStrings` on 2.3 MB prints 2.3 MB. Point at the first difference
/// instead.
fn expectIdentical(path: []const u8, expected: []const u8, actual: []const u8) !void {
    const shared = @min(expected.len, actual.len);
    var at: usize = 0;
    while (at < shared and expected[at] == actual[at]) at += 1;
    if (at == shared and expected.len == actual.len) return;

    const from = at -| 60;
    std.debug.print(
        \\
        \\{s}: round trip differs at byte {d} (expected {d} bytes, wrote {d})
        \\  expected: …{s}
        \\  actual:   …{s}
        \\
    , .{
        path,                                        at,
        expected.len,                                actual.len,
        expected[from..@min(expected.len, at + 60)], actual[from..@min(actual.len, at + 60)],
    });
    return error.RoundTripDiffers;
}

test "data/data.json round-trips byte for byte" {
    try expectRoundTrip(tc.model.Dataset, "data/data.json", 4 << 20);
}

test "data/species-enriched.json round-trips byte for byte" {
    try expectRoundTrip(tc.model.EnrichedDataset, "data/species-enriched.json", 16 << 20);
}

test "data/enrichment.json round-trips byte for byte" {
    try expectRoundTrip(tc.model.EnrichmentDataset, "data/enrichment.json", 16 << 20);
}

test "img/credits.json round-trips byte for byte" {
    try expectRoundTrip(
        std.json.ArrayHashMap(tc.model.ImageCredit),
        "img/credits.json",
        4 << 20,
    );
}

test "slug reproduces every image filename on disk" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const credits = try tc.json.readLeaky(
        std.json.ArrayHashMap(tc.model.ImageCredit),
        arena,
        io,
        .cwd(),
        "img/credits.json",
        .limited(4 << 20),
    );

    var entries = credits.map.iterator();
    while (entries.next()) |entry| {
        const filename = entry.key_ptr.*;
        const extension = std.fs.path.extension(filename);

        const slug = try tc.text.slugAlloc(gpa, entry.value_ptr.latin_name);
        defer gpa.free(slug);

        const expected = try std.mem.concat(gpa, u8, &.{ slug, extension });
        defer gpa.free(expected);

        try std.testing.expectEqualStrings(expected, filename);
    }
    try std.testing.expectEqual(@as(usize, 353), credits.map.count());
}

const source_pdf = "docs/CAUE77-2026-Arbre-fiche-conseil-plantations-fiche.pdf";

// The end-to-end check of the riskiest code in the repository: hardcoded column
// bounds, a four-point row tolerance, a literal list of page furniture and
// three by-hand continuation exceptions, all validated against the file they
// were derived from.
//
// It skips when the PDF is absent, which is the normal case for anyone who
// cloned this repository: the document is the property of the CAUE 77 and is
// not redistributed. `mise run pdf` says how to obtain it.
test "the table parser reproduces the committed species list" {
    const gpa = std.testing.allocator;

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const boxes = std.process.run(gpa, io, .{
        .argv = &.{ "pdftotext", "-bbox", "-f", "8", "-l", "19", source_pdf, "-" },
        .stdout_limit = .limited(8 << 20),
    }) catch return error.SkipZigTest;
    defer gpa.free(boxes.stdout);
    defer gpa.free(boxes.stderr);
    switch (boxes.term) {
        .exited => |code| if (code != 0) return error.SkipZigTest,
        else => return error.SkipZigTest,
    }

    const extracted = try tc.pdf.table.parseLeaky(arena, boxes.stdout);
    const committed = try tc.json.readLeaky(
        tc.model.Dataset,
        arena,
        io,
        .cwd(),
        "data/data.json",
        .limited(4 << 20),
    );

    const rebuilt = try tc.json.stringifyAlloc(gpa, extracted);
    defer gpa.free(rebuilt);
    const reference = try tc.json.stringifyAlloc(gpa, committed.species);
    defer gpa.free(reference);

    try expectIdentical("extracted species", reference, rebuilt);
}
