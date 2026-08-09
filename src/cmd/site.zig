//! `tree-climate site` — generate the static site into site/.
//!
//! Reads data/species-enriched.json and the masters in img/, writes only into
//! the output directory, and makes no network call: everything it publishes is
//! already in the repository.
//!
//! Vite must have run first: the hashed asset filenames come from its manifest.
//! `mise run site` enforces the order.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const imgproc = @import("../imgproc.zig");
const json = @import("../json_util.zig");
const model = @import("../model.zig");
const Host = @import("../host.zig").Host;
const catalogue = @import("../site/catalogue.zig");
const page = @import("../site/page.zig");
const search = @import("../site/search.zig");
const verify = @import("../site/verify.zig");

const Options = struct {
    source: []const u8 = "data/species-enriched.json",
    output: []const u8 = "site",
    limit: ?usize = null,
    /// Fixed by default so two builds of the same data produce the same site.
    /// Readers get variety from the "Autres essences" button, which reshuffles
    /// in the browser; a build has nothing to gain from being unrepeatable.
    seed: u64 = 0,
    quality: u32 = 70,
    /// Link prefix on the 404 page, which is served from an unknown depth.
    base: []const u8 = "/",
    site_url: []const u8 = "",
    images: bool = true,
};

const home_cards = 4;

pub fn run(host: Host, argv: []const []const u8) !void {
    const options = try parseOptions(argv);

    const dataset = try json.readLeaky(
        model.EnrichedDataset,
        host.arena,
        host.io,
        host.root,
        options.source,
        .limited(64 << 20),
    );
    var entries = try catalogue.buildLeaky(host.arena, &dataset);
    if (options.limit) |limit| entries = entries[0..@min(limit, entries.len)];

    const assets = try readManifest(host, options.output);

    // A second arena, reset for each page: peak memory stays at the size of the
    // document plus one page, rather than the document plus all 358.
    var scratch: std.heap.ArenaAllocator = .init(host.gpa);
    defer scratch.deinit();

    var context: page.Context = .{
        .arena = scratch.allocator(),
        .dataset = &dataset,
        .entries = entries,
        .assets = assets,
        .site_url = options.site_url,
    };

    const images = if (options.images)
        try buildImages(host, options, entries)
    else
        ImageReport{};

    try writeCorpus(host, options, entries);

    _ = scratch.reset(.retain_capacity);
    try writePage(host, options, "index.html", page.homePage, .{
        context,
        try sampleLeaky(context.arena, entries, options.seed),
    });

    _ = scratch.reset(.retain_capacity);
    try writePage(host, options, "essences/index.html", page.listPage, .{context});

    _ = scratch.reset(.retain_capacity);
    try writePage(host, options, "credits/index.html", page.creditsPage, .{context});

    _ = scratch.reset(.retain_capacity);
    try writePage(host, options, "404.html", page.notFoundPage, .{ context, options.base });

    const families = try catalogue.familyIndexLeaky(host.arena, entries);
    for (entries, 0..) |entry, at| {
        _ = scratch.reset(.retain_capacity);
        context.arena = scratch.allocator();

        const path = try std.fmt.allocPrint(
            context.arena,
            "essences/{s}/index.html",
            .{entry.slug},
        );
        try writePage(host, options, path, page.speciesPage, .{
            context,
            entry,
            if (at > 0) entries[at - 1] else null,
            if (at + 1 < entries.len) entries[at + 1] else null,
            try relativesLeaky(context.arena, families, entry, at),
        });
    }

    try host.report("{d} sheets, {d} search entries", .{ entries.len, entries.len });
    try host.report("images: {d} built, {d} already current{s}", .{
        images.built,
        images.reused,
        if (images.missing > 0) " (masters missing)" else "",
    });

    _ = scratch.reset(.retain_capacity);
    const findings = try verify.check(scratch.allocator(), &dataset, entries);
    if (findings.len > 0) {
        for (findings[0..@min(findings.len, 20)]) |finding| {
            try host.report("  x {s}: {s}", .{ finding.subject, finding.problem });
        }
        std.process.fatal("{d} licence or attribution problems: nothing published", .{findings.len});
    }
    try host.report("licences, attributions and images verified", .{});
}

// ------------------------------------------------------------------ options

fn parseOptions(argv: []const []const u8) !Options {
    var options: Options = .{};
    var parser: cli.Parser = .init(argv);
    while (parser.next()) |token| switch (token) {
        .option => |option| {
            const name = option.name;
            if (std.mem.eql(u8, name, "source")) {
                options.source = try parser.value(option);
            } else if (std.mem.eql(u8, name, "out")) {
                options.output = try parser.value(option);
            } else if (std.mem.eql(u8, name, "limit")) {
                options.limit = try std.fmt.parseUnsigned(usize, try parser.value(option), 10);
            } else if (std.mem.eql(u8, name, "seed")) {
                options.seed = try std.fmt.parseUnsigned(u64, try parser.value(option), 10);
            } else if (std.mem.eql(u8, name, "quality")) {
                options.quality = try std.fmt.parseUnsigned(u32, try parser.value(option), 10);
            } else if (std.mem.eql(u8, name, "base")) {
                options.base = try parser.value(option);
            } else if (std.mem.eql(u8, name, "site-url")) {
                options.site_url = try parser.value(option);
            } else if (std.mem.eql(u8, name, "no-images")) {
                options.images = false;
            } else {
                std.process.fatal("site: unknown option --{s}", .{name});
            }
        },
        .positional => |value| std.process.fatal("site: unexpected argument '{s}'", .{value}),
    };
    return options;
}

// ------------------------------------------------------------------ assets

const ManifestEntry = struct {
    file: []const u8,
    css: []const []const u8 = &.{},
};

/// The one place the Zig side depends on Vite: it learns the content-hashed
/// filenames rather than guessing them.
fn readManifest(host: Host, output: []const u8) !page.Assets {
    const path = try std.fs.path.join(host.arena, &.{ output, "assets", ".vite", "manifest.json" });
    const manifest = json.readForeignLeaky(
        std.json.ArrayHashMap(ManifestEntry),
        host.arena,
        host.io,
        host.root,
        path,
        .limited(1 << 20),
    ) catch |failure| std.process.fatal(
        "site: cannot read {s} ({t}) — run `pnpm -C web build` first, or `mise run site`",
        .{ path, failure },
    );

    const entry = manifest.map.get("src/main.js") orelse
        std.process.fatal("site: {s} has no entry for src/main.js", .{path});
    if (entry.css.len == 0) std.process.fatal("site: {s} lists no stylesheet", .{path});

    return .{ .script = entry.file, .stylesheet = entry.css[0] };
}

// ------------------------------------------------------------------ output

fn writePage(
    host: Host,
    options: Options,
    relative: []const u8,
    comptime render: anytype,
    arguments: anytype,
) !void {
    const path = try std.fs.path.join(host.arena, &.{ options.output, relative });
    defer host.arena.free(path);

    var atomic = try host.root.createFileAtomic(host.io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(host.io);

    var buffer: [64 * 1024]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, host.io, &buffer);
    try @call(.auto, render, .{&file.interface} ++ arguments);
    try file.interface.flush();
    try atomic.replace(host.io);
}

fn writeCorpus(host: Host, options: Options, entries: []const catalogue.Entry) !void {
    const path = try std.fs.path.join(host.arena, &.{ options.output, "data", "search.json" });
    defer host.arena.free(path);

    var atomic = try host.root.createFileAtomic(host.io, path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(host.io);

    var buffer: [64 * 1024]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, host.io, &buffer);
    try search.write(&file.interface, entries);
    try file.interface.flush();
    try atomic.replace(host.io);
}

const ImageReport = struct { built: usize = 0, reused: usize = 0, missing: usize = 0 };

fn buildImages(host: Host, options: Options, entries: []const catalogue.Entry) !ImageReport {
    var report: ImageReport = .{};
    var scratch: std.heap.ArenaAllocator = .init(host.gpa);
    defer scratch.deinit();

    for (entries) |entry| {
        const image = entry.primary_image orelse continue;
        const master = image.local_file orelse continue;

        _ = scratch.reset(.retain_capacity);
        const arena = scratch.allocator();
        const wide = try std.fmt.allocPrint(arena, "{s}/img/{s}-{d}.webp", .{
            options.output, entry.slug, page.full_width,
        });
        const narrow = try std.fmt.allocPrint(arena, "{s}/img/{s}-{d}.webp", .{
            options.output, entry.slug, page.thumb_width,
        });
        try host.root.createDirPath(host.io, std.fs.path.dirname(wide).?);

        switch (try imgproc.deriveWebp(
            host,
            master,
            wide,
            narrow,
            page.full_width,
            page.thumb_width,
            options.quality,
        )) {
            .built => report.built += 1,
            .reused => report.reused += 1,
            .master_missing => report.missing += 1,
        }
    }
    return report;
}

// ------------------------------------------------------------------ selection

/// Four species drawn at random, rendered server-side so the home page has
/// something to show without JavaScript.
fn sampleLeaky(
    arena: Allocator,
    entries: []const catalogue.Entry,
    seed: u64,
) ![]const catalogue.Entry {
    const wanted = @min(home_cards, entries.len);
    var prng: std.Random.DefaultPrng = .init(seed);
    const random = prng.random();

    const shuffled = try arena.dupe(catalogue.Entry, entries);
    random.shuffle(catalogue.Entry, shuffled);
    return shuffled[0..wanted];
}

/// Indices of the other species in the same family.
fn relativesLeaky(
    arena: Allocator,
    families: catalogue.FamilyIndex,
    entry: catalogue.Entry,
    at: usize,
) ![]const usize {
    const members = families.get(entry.family) orelse return &.{};
    var relatives: std.ArrayList(usize) = .empty;
    for (members.items) |other| {
        if (other != at) try relatives.append(arena, other);
    }
    return relatives.items;
}
