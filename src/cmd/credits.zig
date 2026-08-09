//! `tree-climate credits` — render docs/CREDITS.md.

const std = @import("std");
const cli = @import("../cli.zig");
const credits = @import("../credits.zig");
const json = @import("../json_util.zig");
const model = @import("../model.zig");
const Host = @import("../host.zig").Host;

const Options = struct {
    source: []const u8 = "data/species-enriched.json",
    output: []const u8 = "docs/CREDITS.md",
};

pub fn run(host: Host, argv: []const []const u8) !void {
    var options: Options = .{};
    var parser: cli.Parser = .init(argv);
    while (parser.next()) |token| switch (token) {
        .option => |option| {
            if (std.mem.eql(u8, option.name, "source")) {
                options.source = try parser.value(option);
            } else if (std.mem.eql(u8, option.name, "out")) {
                options.output = try parser.value(option);
            } else {
                std.process.fatal("credits: unknown option --{s}", .{option.name});
            }
        },
        .positional => |value| std.process.fatal("credits: unexpected argument '{s}'", .{value}),
    };

    const dataset = try json.readLeaky(
        model.EnrichedDataset,
        host.arena,
        host.io,
        host.root,
        options.source,
        .limited(64 << 20),
    );

    var atomic = try host.root.createFileAtomic(host.io, options.output, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(host.io);

    var buffer: [64 * 1024]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, host.io, &buffer);
    const total = try render(host.arena, &file.interface, dataset);
    try file.interface.flush();
    try atomic.replace(host.io);

    try host.report("{d} images credited -> {s}", .{ total, options.output });
}

/// Writes the document and returns how many images it credited.
fn render(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    dataset: model.EnrichedDataset,
) !usize {
    const source = dataset.source;
    const coverage = dataset.coverage;

    try out.writeAll(
        \\# Crédits et licences
        \\
        \\Les données de ce dépôt proviennent de plusieurs sources aux licences distinctes. Ce fichier
        \\est **généré** par `tree-climate credits` : ne pas l'éditer à la main.
        \\
        \\## Données de base
        \\
        \\
    );
    try out.print(
        "La liste des essences est extraite de **« {s} »** du **{s}** ({s}), pages {s}, par " ++
            "`tree-climate extract`.\n\n{s}\n\n",
        .{ source.document, source.publisher, source.date, source.pdf_pages, credits.source_notice },
    );
    try out.print(
        "- Présentation et lien de téléchargement : [{s} sur le site de la Société française " ++
            "d'arboriculture]({s})\n",
        .{ source.publisher, source.url },
    );
    try out.print("- Lecture en ligne : [{s}]({s})\n\n", .{ source.title, source.reader_url });

    try out.writeAll("## Sources de l'enrichissement\n\n");
    try out.writeAll("| Source | Apport | Licence |\n|---|---|---|\n");
    for (dataset.references.map.values()) |reference| {
        try out.print("| [{s}]({s}) | {s} | {s} |\n", .{
            reference.name,
            reference.url,
            reference.usage,
            reference.licence,
        });
    }

    try out.writeAll("\n## Licences retenues\n\n");
    try out.writeAll(
        "| Licence | Attribution | Partage à l'identique | Usage commercial |\n|---|---|---|---|\n",
    );
    for (dataset.licences.map.values()) |licence| {
        try out.print("| [{s}]({s}) | {s} | {s} | {s} |\n", .{
            licence.name,
            licence.url,
            yesNo(licence.attribution),
            yesNo(licence.share_alike),
            yesNo(licence.commercial),
        });
    }

    try out.writeAll("\n## Conséquences pour la réutilisation\n\n");
    for (credits.consequences, 1..) |consequence, rank| {
        try out.print("{d}. **{s}.** {s}\n", .{ rank, consequence.title, consequence.body });
    }

    try out.writeAll("\n## Couverture\n\n");
    try out.print(
        "- {d} essences sur {d} avec description (dont {d} en français)\n",
        .{ coverage.with_description, coverage.total, coverage.french_description },
    );
    try out.print(
        "- {d} avec image, {d} sans rien\n",
        .{ coverage.with_image, coverage.with_neither },
    );
    try out.writeAll("- images principales par licence : ");
    var first = true;
    var licences = dataset.licences.map.iterator();
    while (licences.next()) |entry| {
        const count = credits.countByLicence(&dataset, entry.key_ptr.*);
        if (count == 0) continue;
        if (!first) try out.writeAll(", ");
        first = false;
        try out.print("{s} × {d}", .{ entry.value_ptr.name, count });
    }
    try out.writeAll("\n");

    const attributions = try credits.attributionsLeaky(arena, &dataset);
    try out.print("\n## Attribution des {d} images\n\n", .{attributions.len});
    try out.writeAll("| Essence | Auteur | Licence | Fichier source |\n|---|---|---|---|\n");
    for (attributions) |line| {
        try out.print("| *{s}* | {s} | [{s}]({s}) | [source]({s}) |\n", .{
            line.latin_name,
            if (line.author.len > 0) line.author else "—",
            line.licence_name,
            line.licence_url,
            line.source_url,
        });
    }
    return attributions.len;
}

fn yesNo(value: bool) []const u8 {
    return if (value) "oui" else "non";
}
