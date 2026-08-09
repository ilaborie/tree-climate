//! Rebuilds the species table from word bounding boxes.
//!
//! Plain text extraction merges the narrow acidity / moisture / exposure
//! columns into one another, so the table is reconstructed from coordinates
//! instead: words are grouped into rows by their vertical position, then
//! assigned to a column by their left edge.
//!
//! Every constant here is calibrated against one specific document. If
//! `mise run pdf` reports a checksum mismatch, these bounds are the first thing
//! to re-derive.

const std = @import("std");
const Allocator = std.mem.Allocator;
const model = @import("../model.zig");
const xml = @import("xml.zig");

pub const first_page = 8;
pub const last_page = 19;

const Column = enum { latin, french, height, acidity, moisture, exposure, traits };

/// Left-edge bounds in points. The three trait columns are 28 points wide,
/// which is why a coordinate-free extraction cannot tell them apart.
const bounds = [_]struct { limit: f64, column: Column }{
    .{ .limit = 213, .column = .latin },
    .{ .limit = 447, .column = .french },
    .{ .limit = 468, .column = .height },
    .{ .limit = 496, .column = .acidity },
    .{ .limit = 524, .column = .moisture },
    .{ .limit = 552, .column = .exposure },
    .{ .limit = std.math.inf(f64), .column = .traits },
};

/// Two words belong to the same row when their tops are within this many
/// points. Cell text is set on slightly different baselines, so an exact
/// comparison splits rows in two.
const row_tolerance = 4;

const Meaning = struct { code: u8, label: []const u8 };

// Declaration order is output order: the labels of one cell come out in the
// order below, not in the order the letters appear in the source.
const acidity = [_]Meaning{ .{ .code = 'A', .label = "acide" }, .{ .code = 'N', .label = "neutre" }, .{ .code = 'B', .label = "basique" } };
const moisture = [_]Meaning{ .{ .code = 'H', .label = "humide" }, .{ .code = 'F', .label = "frais" }, .{ .code = 'S', .label = "sec" } };
const exposure = [_]Meaning{ .{ .code = 'S', .label = "soleil" }, .{ .code = 'M', .label = "mi-soleil" }, .{ .code = 'O', .label = "ombre" } };
const traits = [_]Meaning{ .{ .code = 'P', .label = "persistant" }, .{ .code = 'S', .label = "semi-persistant" }, .{ .code = 'F', .label = "fruits" } };

/// The legend published alongside the table, derived from the same tables that
/// decode it so the two cannot drift apart.
pub const legend: model.Legend = .{
    .height_m = "hauteur adulte indicative en mètres",
    .acidity = .{ .A = acidity[0].label, .N = acidity[1].label, .B = acidity[2].label },
    .moisture = .{ .H = moisture[0].label, .F = moisture[1].label, .S = moisture[2].label },
    .exposure = .{ .S = exposure[0].label, .M = exposure[1].label, .O = exposure[2].label },
    .availability = .{
        .disponible = "essences disponibles en pépinières en plus ou moins grandes quantités",
        .peu_disponible = "essences pas encore sur le marché français ou en très petites " ++
            "quantités, et essences moins citées",
    },
    .traits = .{ .P = traits[0].label, .S = traits[1].label, .F = traits[2].label },
};

/// Header and footer fragments repeated on each of the twelve pages. A row is
/// dropped only when every one of its non-empty cells is in this set.
const furniture = [_][]const u8{
    "Liste indicative d\u{2019}essences potentiellement",
    "adaptées aux changements climatiques",
    "NOM",
    "LATIN",
    "FRANÇAIS",
    "Hauteur",
    "Acidité",
    "(Acide",
    "Neutre",
    "Basique)",
    "Humidité",
    "(Humide",
    "Frais",
    "Sec)",
    "Exposition",
    "(Soleil",
    "Mi",
    "sol",
    "Ombre)",
    "Persistant,",
    "Semi",
    "persistant,",
    "Fruits",
    "CAUE 77 - Mars 2026",
    "1/12",
    "2/12",
    "3/12",
    "4/12",
    "5/12",
    "6/12",
    "7/12",
    "8/12",
    "9/12",
    "10/12",
    "11/12",
    "12/12",
};

/// Rows whose latin cell is filled but which continue the row above: the name
/// was too long for its cell. Identified by page and by the text of that cell,
/// because nothing in the geometry distinguishes them.
const continuations = [_]struct { page: u32, latin: []const u8 }{
    .{ .page = 9, .latin = "Debeuzevillei" },
    .{ .page = 13, .latin = "CASQUE ROUGE" },
    .{ .page = 14, .latin = "RESISTA® series )" },
};

const available = "disponible";
const scarce = "peu_disponible";

/// Parses the output of `pdftotext -bbox -f 8 -l 19`.
///
/// Leaky: everything returned is allocated in `arena` or borrowed from
/// `bbox_xhtml`, so both must outlive the result.
pub fn parseLeaky(arena: Allocator, bbox_xhtml: []const u8) ![]const model.Species {
    var species: std.ArrayList(model.Species) = .empty;
    var section_title: []const u8 = "";
    var section: ?[]const u8 = null;
    // An index, not a pointer: appending to `species` can move the backing store.
    var current: ?usize = null;

    const rows = try readRows(arena, bbox_xhtml);
    for (rows.items) |row| {
        if (isFurniture(row.cells)) continue;

        const latin = std.mem.trim(u8, row.cells.get(.latin), &std.ascii.whitespace);
        const french = std.mem.trim(u8, row.cells.get(.french), &std.ascii.whitespace);
        const joined = try joinNonEmpty(arena, row.cells);

        // Section headings are written across the table, sometimes over two
        // lines; a lowercase second line continues the heading above it.
        const starts_heading = std.mem.startsWith(u8, joined, "Essences ");
        const continues_heading = current == null and std.mem.startsWith(u8, joined, "essences ");
        if (starts_heading or continues_heading) {
            section_title = if (continues_heading)
                std.mem.trim(u8, try std.mem.concat(arena, u8, &.{ section_title, " ", joined }), &std.ascii.whitespace)
            else
                joined;
            section = if (std.mem.indexOf(u8, section_title, "grandes quantités") != null)
                available
            else
                scarce;
            current = null;
            continue;
        }
        if (section == null) continue;

        const is_continuation = latin.len == 0 or isKnownContinuation(row.page, latin);
        if (is_continuation) {
            if (current) |at| {
                const previous = &species.items[at];
                previous.latin_name = try joinWords(arena, previous.latin_name, latin);
                previous.french_name = try joinWords(arena, previous.french_name, french);
                continue;
            }
        }

        try species.append(arena, .{
            .latin_name = latin,
            .french_name = french,
            .height_m = parseHeight(row.cells.get(.height)),
            .acidity = try decode(arena, row.cells.get(.acidity), &acidity),
            .moisture = try decode(arena, row.cells.get(.moisture), &moisture),
            .exposure = try decode(arena, row.cells.get(.exposure), &exposure),
            .traits = try decode(arena, row.cells.get(.traits), &traits),
            .codes = .{
                .acidity = emptyToNull(row.cells.get(.acidity)),
                .moisture = emptyToNull(row.cells.get(.moisture)),
                .exposure = emptyToNull(row.cells.get(.exposure)),
                .traits = emptyToNull(row.cells.get(.traits)),
            },
            .availability = section.?,
            .section = section_title,
            .pdf_page = row.page,
            .french_names = &.{},
        });
        current = species.items.len - 1;
    }

    // Words split across cell boundaries leave stray spaces inside parentheses.
    for (species.items) |*entry| {
        entry.latin_name = try tidyParentheses(arena, entry.latin_name);
        entry.french_names = try splitNames(arena, entry.french_name);
    }
    return species.items;
}

// ------------------------------------------------------------------ rows

const Cells = std.EnumArray(Column, []const u8);

const Row = struct { page: u32, cells: Cells };

const Word = struct { top: f64, left: f64, text: []const u8 };

fn readRows(arena: Allocator, bbox_xhtml: []const u8) !std.ArrayList(Row) {
    var rows: std.ArrayList(Row) = .empty;
    var words: std.ArrayList(Word) = .empty;
    defer words.deinit(arena);

    var reader: xml.Reader = .init(bbox_xhtml);
    var page: u32 = first_page - 1;
    var pending: ?Word = null;

    while (try reader.next()) |event| switch (event) {
        .open => |element| {
            if (std.mem.eql(u8, element.name, "page")) {
                page += 1;
                words.clearRetainingCapacity();
            } else if (std.mem.eql(u8, element.name, "word")) {
                pending = .{
                    .top = try coordinate(element, "yMin"),
                    .left = try coordinate(element, "xMin"),
                    .text = "",
                };
            }
        },
        .text => |raw| if (pending) |*word| {
            word.text = try xml.decodeAlloc(arena, raw);
        },
        .close => |name| {
            if (std.mem.eql(u8, name, "word")) {
                if (pending) |word| try words.append(arena, word);
                pending = null;
            } else if (std.mem.eql(u8, name, "page")) {
                try appendRowsOfPage(arena, &rows, page, words.items);
            }
        },
    };
    return rows;
}

fn coordinate(element: xml.Element, name: []const u8) !f64 {
    const raw = element.attribute(name) orelse return error.Malformed;
    return std.fmt.parseFloat(f64, raw) catch error.Malformed;
}

fn appendRowsOfPage(arena: Allocator, rows: *std.ArrayList(Row), page: u32, words: []Word) !void {
    // Stable, and ordered exactly as Python's `sorted()` ordered the same
    // tuples: ties must keep document order or the joined cells come out
    // scrambled.
    std.mem.sort(Word, words, {}, lessByPosition);

    var line: std.ArrayList(Word) = .empty;
    defer line.deinit(arena);
    var line_top: f64 = 0;

    for (words) |word| {
        if (line.items.len > 0 and @abs(line_top - word.top) < row_tolerance) {
            try line.append(arena, word);
            continue;
        }
        if (line.items.len > 0) try appendRow(arena, rows, page, line.items);
        line.clearRetainingCapacity();
        line_top = word.top;
        try line.append(arena, word);
    }
    if (line.items.len > 0) try appendRow(arena, rows, page, line.items);
}

fn appendRow(arena: Allocator, rows: *std.ArrayList(Row), page: u32, line: []Word) !void {
    std.mem.sort(Word, line, {}, lessByLeft);

    var parts: std.EnumArray(Column, std.ArrayList([]const u8)) = .initFill(.empty);
    defer for (&parts.values) |*list| list.deinit(arena);
    for (line) |word| try parts.getPtr(columnOf(word.left)).append(arena, word.text);

    var cells: Cells = .initFill("");
    var any = false;
    for (std.enums.values(Column)) |column| {
        const joined = try std.mem.join(arena, " ", parts.get(column).items);
        cells.set(column, joined);
        any = any or joined.len > 0;
    }
    if (any) try rows.append(arena, .{ .page = page, .cells = cells });
}

fn lessByPosition(_: void, a: Word, b: Word) bool {
    if (a.top != b.top) return a.top < b.top;
    if (a.left != b.left) return a.left < b.left;
    return std.mem.lessThan(u8, a.text, b.text);
}

fn lessByLeft(_: void, a: Word, b: Word) bool {
    if (a.left != b.left) return a.left < b.left;
    return std.mem.lessThan(u8, a.text, b.text);
}

fn columnOf(left: f64) Column {
    for (bounds) |bound| {
        if (left < bound.limit) return bound.column;
    }
    return .traits;
}

// ------------------------------------------------------------------ cells

fn isFurniture(cells: Cells) bool {
    for (std.enums.values(Column)) |column| {
        const value = cells.get(column);
        if (value.len == 0) continue;
        var known = false;
        for (furniture) |fragment| known = known or std.mem.eql(u8, value, fragment);
        if (!known) return false;
    }
    return true;
}

fn isKnownContinuation(page: u32, latin: []const u8) bool {
    for (continuations) |entry| {
        if (entry.page == page and std.mem.eql(u8, entry.latin, latin)) return true;
    }
    return false;
}

fn joinNonEmpty(arena: Allocator, cells: Cells) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(arena);
    for (std.enums.values(Column)) |column| {
        const value = cells.get(column);
        if (value.len > 0) try parts.append(arena, value);
    }
    const joined = try std.mem.join(arena, " ", parts.items);
    return std.mem.trim(u8, joined, &std.ascii.whitespace);
}

fn joinWords(arena: Allocator, head: []const u8, tail: []const u8) ![]const u8 {
    const joined = try std.mem.concat(arena, u8, &.{ head, " ", tail });
    return std.mem.trim(u8, joined, &std.ascii.whitespace);
}

fn parseHeight(cell: []const u8) ?u32 {
    const digits = std.mem.trim(u8, cell, &std.ascii.whitespace);
    if (digits.len == 0) return null;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseUnsigned(u32, digits, 10) catch null;
}

fn emptyToNull(cell: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, cell, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

/// Letters of `cell` mapped to labels, in the order the table declares them.
fn decode(arena: Allocator, cell: []const u8, table: []const Meaning) ![]const []const u8 {
    var labels: std.ArrayList([]const u8) = .empty;
    errdefer labels.deinit(arena);
    for (table) |meaning| {
        for (cell) |byte| {
            if (std.ascii.toUpper(byte) == meaning.code) {
                try labels.append(arena, meaning.label);
                break;
            }
        }
    }
    return labels.toOwnedSlice(arena);
}

/// `( Nanguen )` becomes `(Nanguen)`: the words came from separate boxes.
fn tidyParentheses(arena: Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfAny(u8, name, "()") == null) return name;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var at: usize = 0;
    while (at < name.len) : (at += 1) {
        if (name[at] == '(') {
            try out.append(arena, '(');
            while (at + 1 < name.len and std.ascii.isWhitespace(name[at + 1])) at += 1;
            continue;
        }
        if (name[at] == ' ' and at + 1 < name.len and name[at + 1] == ')') continue;
        try out.append(arena, name[at]);
    }
    return out.toOwnedSlice(arena);
}

/// Splits the French name cell on commas, dropping the empty pieces.
fn splitNames(arena: Allocator, cell: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(arena);
    var pieces = std.mem.splitScalar(u8, cell, ',');
    while (pieces.next()) |piece| {
        const name = std.mem.trim(u8, piece, &std.ascii.whitespace);
        if (name.len > 0) try names.append(arena, name);
    }
    return names.toOwnedSlice(arena);
}

// ------------------------------------------------------------------ tests

const testing_gpa = std.testing.allocator;

/// `expectEqualSlices` on slices of slices compares pointers, not text.
fn expectStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

// A table spelled out by hand rather than a slab of the source document: the
// PDF is not redistributed, so the fixtures cannot be either.
const sample =
    \\<doc><page width="595" height="841">
    \\<word xMin="10" yMin="100" xMax="20" yMax="110">NOM</word>
    \\<word xMin="230" yMin="100" xMax="240" yMax="110">FRANÇAIS</word>
    \\<word xMin="10" yMin="200" xMax="20" yMax="210">Essences</word>
    \\<word xMin="60" yMin="200" xMax="70" yMax="210">disponibles</word>
    \\<word xMin="120" yMin="200" xMax="130" yMax="210">en</word>
    \\<word xMin="150" yMin="200" xMax="160" yMax="210">grandes</word>
    \\<word xMin="200" yMin="200" xMax="210" yMax="210">quantités</word>
    \\<word xMin="10" yMin="300" xMax="20" yMax="310">Abies</word>
    \\<word xMin="60" yMin="302" xMax="70" yMax="310">concolor</word>
    \\<word xMin="220" yMin="300" xMax="230" yMax="310">Sapin</word>
    \\<word xMin="260" yMin="300" xMax="270" yMax="310">du</word>
    \\<word xMin="290" yMin="300" xMax="300" yMax="310">Colorado,</word>
    \\<word xMin="350" yMin="300" xMax="360" yMax="310">sapin</word>
    \\<word xMin="450" yMin="300" xMax="460" yMax="310">25</word>
    \\<word xMin="470" yMin="300" xMax="480" yMax="310">AN</word>
    \\<word xMin="500" yMin="300" xMax="510" yMax="310">FS</word>
    \\<word xMin="530" yMin="300" xMax="540" yMax="310">SM</word>
    \\<word xMin="560" yMin="300" xMax="570" yMax="310">P</word>
    \\<word xMin="230" yMin="400" xMax="240" yMax="410">bleu</word>
    \\<word xMin="10" yMin="500" xMax="20" yMax="510">Acer</word>
    \\<word xMin="60" yMin="500" xMax="70" yMax="510">(</word>
    \\<word xMin="80" yMin="500" xMax="90" yMax="510">rubrum</word>
    \\<word xMin="140" yMin="500" xMax="150" yMax="510">)</word>
    \\</page></doc>
;

test "reconstructs a row from its word boxes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const species = try parseLeaky(arena_state.allocator(), sample);
    try std.testing.expectEqual(@as(usize, 2), species.len);

    const first = species[0];
    try std.testing.expectEqualStrings("Abies concolor", first.latin_name);
    try std.testing.expectEqualStrings("Sapin du Colorado, sapin bleu", first.french_name);
    try std.testing.expectEqual(@as(?u32, 25), first.height_m);
    try std.testing.expectEqualStrings("disponible", first.availability);
    try std.testing.expectEqual(@as(u32, 8), first.pdf_page);
}

test "the header row is dropped and the section heading names the section" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const species = try parseLeaky(arena_state.allocator(), sample);
    try std.testing.expectEqualStrings(
        "Essences disponibles en grandes quantités",
        species[0].section,
    );
}

test "letters decode to labels in table order, not input order" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const species = try parseLeaky(arena_state.allocator(), sample);
    const first = species[0];

    try expectStrings(&.{ "acide", "neutre" }, first.acidity);
    // "FS" is written F then S, but the legend declares humide, frais, sec.
    try expectStrings(&.{ "frais", "sec" }, first.moisture);
    // "SM" likewise: soleil comes before mi-soleil.
    try expectStrings(&.{ "soleil", "mi-soleil" }, first.exposure);
    try expectStrings(&.{"persistant"}, first.traits);
    try std.testing.expectEqualStrings("AN", first.codes.acidity.?);
    try std.testing.expect(species[1].codes.traits == null);
}

test "a row with an empty latin cell continues the row above" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const species = try parseLeaky(arena_state.allocator(), sample);
    // "bleu" sat alone on its own line under the French column.
    try expectStrings(&.{ "Sapin du Colorado", "sapin bleu" }, species[0].french_names);
}

test "spaces inside parentheses are closed up" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const species = try parseLeaky(arena_state.allocator(), sample);
    try std.testing.expectEqualStrings("Acer (rubrum)", species[1].latin_name);
}

test "rows before any section heading are ignored" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    const orphan =
        \\<doc><page>
        \\<word xMin="10" yMin="100" xMax="20" yMax="110">Abies</word>
        \\</page></doc>
    ;
    const species = try parseLeaky(arena_state.allocator(), orphan);
    try std.testing.expectEqual(@as(usize, 0), species.len);
}

test "the table parser survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(testing_gpa, struct {
        fn run(gpa: Allocator) !void {
            var arena_state: std.heap.ArenaAllocator = .init(gpa);
            defer arena_state.deinit();
            _ = try parseLeaky(arena_state.allocator(), sample);
        }
    }.run, .{});
}
