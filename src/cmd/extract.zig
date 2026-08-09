//! `tree-climate extract` — rebuild data/data.json from the source PDF.

const std = @import("std");
const cli = @import("../cli.zig");
const csv = @import("../csv.zig");
const json = @import("../json_util.zig");
const model = @import("../model.zig");
const table = @import("../pdf/table.zig");
const Host = @import("../host.zig").Host;

const default_pdf = "docs/CAUE77-2026-Arbre-fiche-conseil-plantations-fiche.pdf";
const default_output = "data/data.json";

// The PDF is not versioned: it stays the property of the CAUE 77. Recording
// where to get it is what keeps the extraction verifiable without
// redistributing the document.
const presentation_url =
    "https://sfa-asso.fr/realiser-des-plantations-adaptees-aux-changements-climatiques-caue77/";
const reader_url = "https://www.calameo.com/caue77/read/00598818161c83dc963fb";

const sections = [_]struct { availability: []const u8, file: []const u8 }{
    .{ .availability = "disponible", .file = "species-available.csv" },
    .{ .availability = "peu_disponible", .file = "species-scarce.csv" },
};

const csv_header = [_][]const u8{
    "latin_name", "french_name", "height_m", "acidity",
    "moisture",   "exposure",    "traits",   "pdf_page",
};

pub fn run(host: Host, argv: []const []const u8) !void {
    var pdf_path: []const u8 = default_pdf;
    var output_path: []const u8 = default_output;

    var parser: cli.Parser = .init(argv);
    while (parser.next()) |token| switch (token) {
        .option => |option| {
            if (std.mem.eql(u8, option.name, "pdf")) {
                pdf_path = try parser.value(option);
            } else if (std.mem.eql(u8, option.name, "out")) {
                output_path = try parser.value(option);
            } else {
                std.process.fatal("extract: unknown option --{s}", .{option.name});
            }
        },
        .positional => |value| std.process.fatal("extract: unexpected argument '{s}'", .{value}),
    };

    const boxes = try host.runChecked(.{ .argv = &.{
        "pdftotext",
        "-bbox",
        "-f",
        std.fmt.comptimePrint("{d}", .{table.first_page}),
        "-l",
        std.fmt.comptimePrint("{d}", .{table.last_page}),
        pdf_path,
        "-",
    } });
    defer boxes.deinit(host.gpa);

    // The parse copies out of `boxes.stdout` rather than borrowing from it, so
    // freeing the subprocess output above is safe.
    const species = try table.parseLeaky(host.arena, boxes.stdout);
    if (species.len == 0) {
        std.process.fatal("extract: no rows found in {s} — have the column bounds moved?", .{pdf_path});
    }

    try json.writeAtomic(host.io, host.root, output_path, model.Dataset{
        .source = .{
            .title = "Liste indicative d\u{2019}essences potentiellement adaptées " ++
                "aux changements climatiques",
            .document = "Réaliser des plantations adaptées aux changements climatiques " ++
                "– fiche conseil",
            .publisher = "CAUE 77",
            .date = "Mars 2026",
            .file = std.fs.path.basename(pdf_path),
            .url = presentation_url,
            .reader_url = reader_url,
            .pdf_pages = std.fmt.comptimePrint("{d}-{d}", .{ table.first_page, table.last_page }),
        },
        .legend = table.legend,
        .species_count = @intCast(species.len),
        .species = species,
    });
    try host.report("{d} species -> {s}", .{ species.len, output_path });

    const directory = std.fs.path.dirname(output_path) orelse ".";
    for (sections) |section| {
        const path = try std.fs.path.join(host.arena, &.{ directory, section.file });
        const written = try writeSection(host, path, species, section.availability);
        try host.report("{d} species -> {s}", .{ written, path });
    }
}

/// Writes the rows of one section as a flat CSV, and returns how many there were.
fn writeSection(
    host: Host,
    path: []const u8,
    species: []const model.Species,
    availability: []const u8,
) !usize {
    var atomic = try host.root.createFileAtomic(host.io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(host.io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(atomic.file, host.io, &buffer);
    var out: csv.Writer = .{ .out = &file_writer.interface };

    try out.fields(&csv_header);
    try out.endRow();

    var written: usize = 0;
    var height: [8]u8 = undefined;
    var page: [8]u8 = undefined;
    for (species) |entry| {
        if (!std.mem.eql(u8, entry.availability, availability)) continue;
        written += 1;

        try out.field(entry.latin_name);
        try out.field(entry.french_name);
        try out.field(if (entry.height_m) |metres|
            try std.fmt.bufPrint(&height, "{d}", .{metres})
        else
            "");
        try out.joined(host.gpa, entry.acidity);
        try out.joined(host.gpa, entry.moisture);
        try out.joined(host.gpa, entry.exposure);
        try out.joined(host.gpa, entry.traits);
        try out.field(try std.fmt.bufPrint(&page, "{d}", .{entry.pdf_page}));
        try out.endRow();
    }

    try file_writer.interface.flush();
    try atomic.replace(host.io);
    return written;
}
