//! String transformations shared by every stage.
//!
//! Both functions here reproduce Python behaviour byte for byte, because
//! artefacts already on disk depend on them: `slug` names the 353 files in
//! `img/` and every entry under `data/cache/`, and `fold` decides which French
//! names are duplicates of each other.

const std = @import("std");
const Allocator = std.mem.Allocator;

const MULTIPLICATION_SIGN = '\u{00D7}';
const RIGHT_SINGLE_QUOTE = '\u{2019}';

/// A filesystem- and URL-safe identifier.
///
/// Runs of anything outside `[a-z0-9]` collapse to a single `-`; the
/// multiplication sign becomes `-mult-` so that `Quercus × turneri` and
/// `Quercus x turneri` stay distinct keys, since conflating them would read
/// back the wrong cache entry. Names longer than 80 characters, or that reduce
/// to nothing, get a SHA-1 suffix.
///
/// Case folding is ASCII-only. Python's `str.lower()` is not, but the two agree
/// for every input in this corpus: a non-ASCII letter is outside `[a-z0-9]`
/// either way, so it becomes `-` whether or not it was lowered first. They
/// would diverge on `İ` (U+0130) and `K` (U+212A), which lower into ASCII
/// letters; neither occurs, and `site.verify` fails the build if one appears.
pub fn slugAlloc(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var substituted: std.ArrayList(u8) = .empty;
    defer substituted.deinit(gpa);
    for (text) |byte| {
        switch (byte) {
            'A'...'Z' => try substituted.append(gpa, byte + ('a' - 'A')),
            else => try substituted.append(gpa, byte),
        }
    }
    try replaceInPlace(gpa, &substituted, "\u{00D7}", "-mult-");

    var base: std.ArrayList(u8) = .empty;
    errdefer base.deinit(gpa);
    var in_separator = false;
    for (substituted.items) |byte| {
        if (isSlugByte(byte)) {
            try base.append(gpa, byte);
            in_separator = false;
        } else if (!in_separator) {
            try base.append(gpa, '-');
            in_separator = true;
        }
    }
    trimHyphens(&base);

    if (base.items.len <= 80 and base.items.len > 0) return base.toOwnedSlice(gpa);

    var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
    std.crypto.hash.Sha1.hash(text, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);

    base.shrinkRetainingCapacity(@min(base.items.len, 80));
    try base.append(gpa, '-');
    try base.appendSlice(gpa, hex[0..8]);
    trimHyphens(&base);
    return base.toOwnedSlice(gpa);
}

fn isSlugByte(byte: u8) bool {
    return switch (byte) {
        'a'...'z', '0'...'9' => true,
        else => false,
    };
}

fn trimHyphens(list: *std.ArrayList(u8)) void {
    const trimmed = std.mem.trim(u8, list.items, "-");
    std.mem.copyForwards(u8, list.items, trimmed);
    list.shrinkRetainingCapacity(trimmed.len);
}

/// Compares two names without being fooled by case, accents, the hybrid sign or
/// stray spacing. Used to tell whether a "vernacular name" from Wikidata is
/// really the latin name wearing a hat.
///
/// This is Python's `unicodedata.normalize("NFD", …)` followed by dropping
/// combining marks, restricted to the Latin-1 Supplement. Characters with no
/// canonical decomposition keep their identity — `ß` stays `ß`, `ø` stays `ø`,
/// `æ` stays `æ` — exactly as Python leaves them. What this does *not* do is
/// full NFD: Latin Extended-A and beyond pass through unfolded. Nothing in the
/// corpus needs them, and `site.verify` fails the build if that changes.
pub fn foldAlloc(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    var stripped: std.ArrayList(u8) = .empty;
    defer stripped.deinit(gpa);

    var codepoints = (std.unicode.Utf8View.init(text) catch
        return gpa.dupe(u8, text)).iterator();
    var encoded: [4]u8 = undefined;
    while (codepoints.nextCodepoint()) |codepoint| {
        // Combining marks are what NFD would have peeled off; drop them so
        // decomposed input folds the same as precomposed input.
        if (codepoint >= 0x0300 and codepoint <= 0x036F) continue;

        const lowered = lowerCodepoint(codepoint);
        if (asciiBase(lowered)) |base| {
            try stripped.append(gpa, base);
            continue;
        }
        const length = std.unicode.utf8Encode(lowered, &encoded) catch unreachable;
        try stripped.appendSlice(gpa, encoded[0..length]);
    }

    try replaceInPlace(gpa, &stripped, " x ", " ");

    var folded: std.ArrayList(u8) = .empty;
    errdefer folded.deinit(gpa);
    var in_space = false;
    for (stripped.items) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!in_space) try folded.append(gpa, ' ');
            in_space = true;
        } else {
            try folded.append(gpa, byte);
            in_space = false;
        }
    }
    const trimmed = std.mem.trim(u8, folded.items, " ");
    std.mem.copyForwards(u8, folded.items, trimmed);
    folded.shrinkRetainingCapacity(trimmed.len);
    return folded.toOwnedSlice(gpa);
}

fn lowerCodepoint(codepoint: u21) u21 {
    return switch (codepoint) {
        'A'...'Z' => codepoint + ('a' - 'A'),
        // Latin-1 Supplement uppercase, minus U+00D7 which is a maths sign.
        0x00C0...0x00D6, 0x00D8...0x00DE => codepoint + 0x20,
        RIGHT_SINGLE_QUOTE => '\'',
        else => codepoint,
    };
}

/// The base letter of a lowercase Latin-1 character that canonically
/// decomposes, or null when it does not decompose at all.
fn asciiBase(codepoint: u21) ?u8 {
    return switch (codepoint) {
        0x00E0...0x00E5 => 'a', // à á â ã ä å
        0x00E7 => 'c', // ç
        0x00E8...0x00EB => 'e', // è é ê ë
        0x00EC...0x00EF => 'i', // ì í î ï
        0x00F1 => 'n', // ñ
        0x00F2...0x00F6 => 'o', // ò ó ô õ ö
        0x00F9...0x00FC => 'u', // ù ú û ü
        0x00FD, 0x00FF => 'y', // ý ÿ
        MULTIPLICATION_SIGN => 'x',
        else => if (codepoint < 0x80) @intCast(codepoint) else null,
    };
}

/// Replaces every non-overlapping occurrence of `needle`, scanning left to
/// right over the original — the semantics of Python's `str.replace`.
fn replaceInPlace(
    gpa: Allocator,
    list: *std.ArrayList(u8),
    comptime needle: []const u8,
    comptime replacement: []const u8,
) Allocator.Error!void {
    if (std.mem.indexOf(u8, list.items, needle) == null) return;

    var rebuilt: std.ArrayList(u8) = .empty;
    errdefer rebuilt.deinit(gpa);
    var rest = list.items;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        try rebuilt.appendSlice(gpa, rest[0..at]);
        try rebuilt.appendSlice(gpa, replacement);
        rest = rest[at + needle.len ..];
    }
    try rebuilt.appendSlice(gpa, rest);

    list.deinit(gpa);
    list.* = rebuilt;
}

const expectEqualStrings = std.testing.expectEqualStrings;
const testing_gpa = std.testing.allocator;

fn expectSlug(expected: []const u8, input: []const u8) !void {
    const actual = try slugAlloc(testing_gpa, input);
    defer testing_gpa.free(actual);
    try expectEqualStrings(expected, actual);
}

fn expectFold(expected: []const u8, input: []const u8) !void {
    const actual = try foldAlloc(testing_gpa, input);
    defer testing_gpa.free(actual);
    try expectEqualStrings(expected, actual);
}

test "slug lowercases and collapses" {
    try expectSlug("abies-concolor", "Abies concolor");
    try expectSlug("pyrus-salicifolia-pendula", "Pyrus salicifolia 'Pendula'");
    try expectSlug("ulmus-nanguen-lutece", "Ulmus 'Nanguen' LUTECE®");
}

test "slug keeps the two spellings of a hybrid apart" {
    try expectSlug("quercus-mult-kewensis", "Quercus × kewensis");
    try expectSlug("quercus-x-kewensis", "Quercus x kewensis");
}

test "slug suffixes names that reduce to nothing" {
    // sha1("×") = 6f4d1a2c…
    const actual = try slugAlloc(testing_gpa, "×");
    defer testing_gpa.free(actual);
    try expectEqualStrings("mult", actual);

    const empty = try slugAlloc(testing_gpa, "—");
    defer testing_gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 8), empty.len);
}

test "slug suffixes names longer than eighty characters" {
    const long = "a" ** 100;
    const actual = try slugAlloc(testing_gpa, long);
    defer testing_gpa.free(actual);
    try std.testing.expectEqual(@as(usize, 80 + 1 + 8), actual.len);
    try expectEqualStrings("a" ** 80, actual[0..80]);
    try std.testing.expectEqual(@as(u8, '-'), actual[80]);
}

test "fold strips accents, case and the hybrid sign" {
    try expectFold("chene vert", "Chêne vert");
    try expectFold("quercus kewensis", "Quercus × kewensis");
    try expectFold("quercus kewensis", "Quercus x kewensis");
    try expectFold("l'if", "L’if");
}

test "fold leaves characters that do not canonically decompose" {
    // Python's NFD does not touch these, so neither do we.
    try expectFold("straße", "Straße");
    try expectFold("øre", "Øre");
    try expectFold("ærø", "Ærø");
}

test "fold agrees on precomposed and decomposed input" {
    try expectFold("eleve", "élève");
    try expectFold("eleve", "e\u{0301}le\u{0300}ve");
}

test "fold squeezes and trims whitespace" {
    try expectFold("a b", "  a \t\n b  ");
}

test "slug and fold survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_gpa, struct {
        fn run(allocator: Allocator) !void {
            const slug = try slugAlloc(allocator, "Quercus × turneri 'Pseudoturneri'");
            defer allocator.free(slug);
            const folded = try foldAlloc(allocator, "Chêne × de Turner");
            defer allocator.free(folded);
        }
    }.run, .{});
}

test "slug and fold never panic on arbitrary bytes" {
    try std.testing.fuzz({}, fuzzTextTransforms, .{});
}

fn fuzzTextTransforms(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    var buffer: [256]u8 = undefined;
    const input = buffer[0..smith.slice(&buffer)];

    const slug = try slugAlloc(testing_gpa, input);
    defer testing_gpa.free(slug);
    for (slug) |byte| try std.testing.expect(isSlugByte(byte) or byte == '-');
    try std.testing.expect(slug.len <= 89);

    const folded = try foldAlloc(testing_gpa, input);
    defer testing_gpa.free(folded);
    try std.testing.expect(folded.len == 0 or
        (folded[0] != ' ' and folded[folded.len - 1] != ' '));
}
