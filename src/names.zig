//! Normalising the scientific names of the source table before querying
//! taxonomic databases.
//!
//! The CAUE list mixes cultivars ("Ulmus 'Nanguen' LUTECE®"), trademarks,
//! wrongly capitalised infraspecific ranks ("subsp. Ginnala") and a few typos.
//! None of that survives contact with GBIF unaltered.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ranks = [_][]const u8{ "subsp.", "ssp.", "var.", "f.", "cv." };

pub const Rank = enum {
    cultivar,
    hybride,
    sous_espece,
    variete,
    forme,
    genre,
    espece,

    pub fn name(self: Rank) []const u8 {
        return @tagName(self);
    }
};

/// Drops cultivar names and trademarks, capitalises the genus and lowercases
/// the rest.
pub fn normaliseLeaky(arena: Allocator, latin_name: []const u8) ![]const u8 {
    const stripped = try stripDecoration(arena, latin_name);

    var words: std.ArrayList([]const u8) = .empty;
    var genus_seen = false;
    var pieces = std.mem.tokenizeAny(u8, stripped, " \t\n\r");
    while (pieces.next()) |piece| {
        // An all-caps word is a trademark, not a taxon: "LUTECE" in
        // "Ulmus 'Nanguen' LUTECE®".
        if (isShouted(piece)) continue;
        if (isHybridMarker(piece)) {
            try words.append(arena, "x");
            continue;
        }
        if (!genus_seen) {
            genus_seen = true;
            try words.append(arena, try capitalise(arena, piece));
        } else {
            try words.append(arena, try lowercase(arena, piece));
        }
    }
    return std.mem.join(arena, " ", words.items);
}

/// The fallback cascade: full name, then without the infraspecific rank, then
/// the binomial, then the genus. The order is load-bearing -- callers treat the
/// first entry as *the* canonical name.
pub fn candidatesLeaky(arena: Allocator, latin_name: []const u8) ![]const []const u8 {
    const normalised = try normaliseLeaky(arena, latin_name);

    var words: std.ArrayList([]const u8) = .empty;
    var pieces = std.mem.tokenizeScalar(u8, normalised, ' ');
    while (pieces.next()) |piece| try words.append(arena, piece);
    if (words.items.len > 0 and std.mem.eql(u8, words.items[words.items.len - 1], "sp.")) {
        _ = words.pop();
    }

    const truncated = beforeInfraspecificRank(words.items);
    var significant: std.ArrayList([]const u8) = .empty;
    for (truncated) |word| {
        if (!std.mem.eql(u8, word, "x")) try significant.append(arena, word);
    }

    const proposals = [_][]const []const u8{
        words.items,
        truncated,
        significant.items[0..@min(2, significant.items.len)],
        significant.items[0..@min(1, significant.items.len)],
    };

    var kept: std.ArrayList([]const u8) = .empty;
    for (proposals) |proposal| {
        const joined = try std.mem.join(arena, " ", proposal);
        const trimmed = std.mem.trimEnd(
            u8,
            std.mem.trim(u8, joined, &std.ascii.whitespace),
            ".",
        );
        if (trimmed.len <= 2) continue;
        var known = false;
        for (kept.items) |already| known = known or std.mem.eql(u8, already, trimmed);
        if (!known) try kept.append(arena, trimmed);
    }
    return kept.items;
}

/// The apparent rank of the name as written in the PDF, before any resolution.
pub fn estimatedRank(latin_name: []const u8) Rank {
    if (hasCultivarQuotes(latin_name) or hasTrademark(latin_name)) return .cultivar;

    var lowered: [512]u8 = undefined;
    const lower = asciiLowerInto(&lowered, latin_name);

    if (containsWord(lower, "x") or std.mem.indexOf(u8, latin_name, "×") != null) return .hybride;
    for ([_]struct { marker: []const u8, rank: Rank }{
        .{ .marker = "subsp.", .rank = .sous_espece },
        .{ .marker = "ssp.", .rank = .sous_espece },
        .{ .marker = "var.", .rank = .variete },
        .{ .marker = " f. ", .rank = .forme },
    }) |candidate| {
        if (std.mem.indexOf(u8, lower, candidate.marker) != null) return candidate.rank;
    }
    if (std.mem.endsWith(u8, lower, " sp.")) return .genre;

    var pieces = std.mem.tokenizeAny(u8, lower, " \t\n\r");
    var count: usize = 0;
    while (pieces.next()) |_| count += 1;
    return if (count == 1) .genre else .espece;
}

// ------------------------------------------------------------------ internals

/// Removes quoted cultivar names, parenthesised asides and trademark signs.
fn stripDecoration(arena: Allocator, latin_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var codepoints = (std.unicode.Utf8View.init(latin_name) catch
        return arena.dupe(u8, latin_name)).iterator();

    var closing: ?u21 = null;
    var encoded: [4]u8 = undefined;
    while (codepoints.nextCodepoint()) |codepoint| {
        if (closing) |wanted| {
            if (codepoint == wanted) closing = null;
            continue;
        }
        switch (codepoint) {
            '\'' => {
                closing = '\'';
                try out.append(arena, ' ');
            },
            '"' => {
                closing = '"';
                try out.append(arena, ' ');
            },
            '\u{00AB}' => { // «
                closing = '\u{00BB}';
                try out.append(arena, ' ');
            },
            '(' => {
                closing = ')';
                try out.append(arena, ' ');
            },
            // Trademark signs vanish entirely, so LUTECE® becomes LUTECE and is
            // then dropped for being all caps.
            '\u{00AE}', '\u{2122}', '\u{00A9}' => {},
            '\u{00D7}' => try out.appendSlice(arena, " x "),
            else => {
                const length = std.unicode.utf8Encode(codepoint, &encoded) catch continue;
                try out.appendSlice(arena, encoded[0..length]);
            },
        }
    }
    return out.items;
}

fn hasCultivarQuotes(name: []const u8) bool {
    for ([_][2][]const u8{
        .{ "'", "'" },
        .{ "\"", "\"" },
        .{ "\u{00AB}", "\u{00BB}" },
    }) |pair| {
        const open = std.mem.indexOf(u8, name, pair[0]) orelse continue;
        if (std.mem.indexOfPos(u8, name, open + pair[0].len, pair[1]) != null) return true;
    }
    return false;
}

fn hasTrademark(name: []const u8) bool {
    for ([_][]const u8{ "\u{00AE}", "\u{2122}", "\u{00A9}" }) |sign| {
        if (std.mem.indexOf(u8, name, sign) != null) return true;
    }
    return false;
}

fn isShouted(word: []const u8) bool {
    if (word.len <= 1) return false;
    var letters: usize = 0;
    for (word) |byte| {
        if (std.ascii.isLower(byte)) return false;
        if (std.ascii.isUpper(byte)) letters += 1;
    }
    return letters > 0;
}

fn isHybridMarker(word: []const u8) bool {
    return word.len == 1 and (word[0] == 'x' or word[0] == 'X');
}

fn beforeInfraspecificRank(words: []const []const u8) []const []const u8 {
    for (words, 0..) |word, at| {
        for (ranks) |rank| {
            if (std.mem.eql(u8, word, rank)) return words[0..at];
        }
    }
    return words;
}

fn capitalise(arena: Allocator, word: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, word);
    for (copy) |*byte| byte.* = std.ascii.toLower(byte.*);
    if (copy.len > 0) copy[0] = std.ascii.toUpper(copy[0]);
    return copy;
}

fn lowercase(arena: Allocator, word: []const u8) ![]const u8 {
    const copy = try arena.dupe(u8, word);
    for (copy) |*byte| byte.* = std.ascii.toLower(byte.*);
    return copy;
}

fn asciiLowerInto(buffer: []u8, value: []const u8) []const u8 {
    const length = @min(buffer.len, value.len);
    for (value[0..length], buffer[0..length]) |byte, *slot| slot.* = std.ascii.toLower(byte);
    return buffer[0..length];
}

/// Whether `word` appears as a whole word, the way Python tested
/// `" x " in f" {name} "`.
fn containsWord(haystack: []const u8, word: []const u8) bool {
    var pieces = std.mem.tokenizeAny(u8, haystack, " \t\n\r");
    while (pieces.next()) |piece| {
        if (std.mem.eql(u8, piece, word)) return true;
    }
    return false;
}

const testing_gpa = std.testing.allocator;

fn expectNormalised(expected: []const u8, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings(
        expected,
        try normaliseLeaky(arena_state.allocator(), input),
    );
}

test "normalising drops cultivars, trademarks and shouted brand names" {
    try expectNormalised("Abies concolor", "Abies concolor");
    try expectNormalised("Ulmus", "Ulmus 'Nanguen' LUTECE®");
    try expectNormalised("Acer campestre", "Acer campestre (Elsrijk)");
    try expectNormalised("Quercus x turneri", "Quercus × turneri");
}

test "an all-caps word is dropped even when it is the genus" {
    // Surprising, and deliberate: the rule exists to remove trademarks, and it
    // cannot tell one from a genus someone shouted. Nothing in the source table
    // writes a genus that way, so the rule earns its keep.
    try expectNormalised("Negundo", "ACER negundo");
    try expectNormalised("Quercus subsp. macrolepis", "quercus ITHABURENSIS subsp. Macrolepis");
}

fn expectCascade(expected: []const []const u8, input: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const cascade = try candidatesLeaky(arena_state.allocator(), input);
    try std.testing.expectEqual(expected.len, cascade.len);
    for (expected, cascade) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "the candidate cascade goes from the full name down to the genus" {
    try expectCascade(
        &.{ "Quercus ithaburensis subsp. macrolepis", "Quercus ithaburensis", "Quercus" },
        "Quercus ithaburensis subsp. macrolepis",
    );
    try expectCascade(&.{ "Pinus nigra f. pyramidalis", "Pinus nigra", "Pinus" }, "Pinus nigra f. pyramidalis");
    try expectCascade(&.{ "Acer campestre", "Acer" }, "Acer campestre (Elsrijk)");
    try expectCascade(&.{"Ulmus"}, "Ulmus 'Nanguen' LUTECE®");
}

test "the hybrid marker is dropped when narrowing to a binomial" {
    try expectCascade(&.{ "Quercus x turneri", "Quercus turneri", "Quercus" }, "Quercus × turneri");
}

test "a bare genus loses its sp. suffix" {
    try expectCascade(&.{"Quercus"}, "Quercus sp.");
}

test "ranks are read off the name as written" {
    try std.testing.expectEqual(Rank.cultivar, estimatedRank("Ulmus 'Nanguen'"));
    try std.testing.expectEqual(Rank.cultivar, estimatedRank("Ulmus LUTECE®"));
    try std.testing.expectEqual(Rank.hybride, estimatedRank("Quercus × turneri"));
    try std.testing.expectEqual(Rank.hybride, estimatedRank("Quercus x turneri"));
    try std.testing.expectEqual(Rank.sous_espece, estimatedRank("Quercus ithaburensis subsp. macrolepis"));
    try std.testing.expectEqual(Rank.variete, estimatedRank("Acer campestre var. austriacum"));
    try std.testing.expectEqual(Rank.forme, estimatedRank("Pinus nigra f. pyramidalis"));
    try std.testing.expectEqual(Rank.genre, estimatedRank("Quercus"));
    try std.testing.expectEqual(Rank.genre, estimatedRank("Quercus sp."));
    try std.testing.expectEqual(Rank.espece, estimatedRank("Quercus robur"));
    try std.testing.expectEqual(Rank.espece, estimatedRank("ACER negundo"));
}

test "name handling survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_gpa, struct {
        fn run(gpa: Allocator) !void {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            _ = try candidatesLeaky(arena_state.allocator(), "Ulmus 'Nanguen' LUTECE® × minor");
        }
    }.run, .{});
}
