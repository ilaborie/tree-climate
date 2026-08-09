//! `tree-climate images` — download the principal image of each species.
//!
//! The URL fetched is the one the Commons API returned: Wikimedia refuses
//! hand-built thumbnail URLs at widths it does not serve. Images are then
//! recompressed to progressive JPEG, which thirds the weight of the PNGs and
//! takes a third off the Typst PDF.
//!
//! Only the principal image is downloaded; the others stay as URLs in
//! data/enrichment.json, so nothing is hotlinked from someone else's server.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const merge = @import("../merge.zig");
const model = @import("../model.zig");
const text = @import("../text.zig");
const Host = @import("../host.zig").Host;

/// jj refuses to snapshot a file larger than this, and an image that big is a
/// mistake anyway at the size a sheet displays.
const maximum_bytes = 2 * 1024 * 1024;
const default_quality = 75;

const extensions = [_][]const u8{ ".jpg", ".jpeg", ".png", ".gif", ".webp" };

const Options = struct {
    enrichment: []const u8 = "data/enrichment.json",
    source: []const u8 = "data/data.json",
    merged: []const u8 = "data/species-enriched.json",
    directory: []const u8 = "img",
    limit: ?usize = null,
    /// 0 keeps the original bytes untouched.
    quality: u32 = default_quality,
    force: bool = false,
};

pub fn run(host: Host, argv: []const []const u8) !void {
    const options = try parseOptions(argv);
    const arena = host.arena;

    var enrichment = try json.readLeaky(
        model.EnrichmentDataset,
        arena,
        host.io,
        host.root,
        options.enrichment,
        .limited(64 << 20),
    );

    // A partial run must not prune: the files it did not look at are not
    // leftovers. Getting this inverted wipes the image set.
    const partial = options.limit != null;
    const count = @min(options.limit orelse enrichment.species.map.count(), enrichment.species.map.count());

    var manifest: std.json.ArrayHashMap(model.ImageCredit) = json.readLeaky(
        std.json.ArrayHashMap(model.ImageCredit),
        arena,
        host.io,
        host.root,
        try std.fs.path.join(arena, &.{ options.directory, "credits.json" }),
        .limited(8 << 20),
    ) catch .{};

    var kept: std.ArrayList([]const u8) = .empty;
    var downloaded: usize = 0;
    var reused: usize = 0;
    var failures: std.ArrayList([]const u8) = .empty;

    for (enrichment.species.map.keys()[0..count], enrichment.species.map.values()[0..count]) |latin_name, *record| {
        const image = primaryImage(record) orelse continue;
        const slug = try text.slugAlloc(arena, latin_name);

        const existing = try existingCopy(host, options, slug);
        const filename = if (existing != null and !options.force)
            existing.?
        else
            fetchLeaky(host, arena, options, slug, image.url, existing) catch |failure| {
                std.log.warn("{s}: {t}", .{ latin_name, failure });
                try failures.append(arena, latin_name);
                continue;
            };
        if (existing != null and !options.force) reused += 1 else downloaded += 1;

        try kept.append(arena, filename);
        image.local_file = try std.fmt.allocPrint(arena, "{s}/{s}", .{ options.directory, filename });
        try manifest.map.put(arena, filename, .{
            .latin_name = latin_name,
            .source = image.source,
            .licence = image.licence,
            .licence_url = image.licence_url,
            .author = image.author,
            .credit = image.credit,
            .source_url = image.source_url,
        });
    }

    var pruned: usize = 0;
    if (!partial) pruned = try pruneOrphans(host, arena, options, kept.items, &manifest);

    sortManifest(&manifest);
    try json.writeAtomic(
        host.io,
        host.root,
        try std.fs.path.join(arena, &.{ options.directory, "credits.json" }),
        manifest,
    );
    try json.writeAtomic(host.io, host.root, options.enrichment, enrichment);

    const dataset = try json.readLeaky(
        model.Dataset,
        arena,
        host.io,
        host.root,
        options.source,
        .limited(16 << 20),
    );
    try json.writeAtomic(host.io, host.root, options.merged, try merge.mergeLeaky(
        arena,
        dataset,
        dataset.species,
        enrichment,
    ));

    try host.report(
        "{d} downloaded, {d} already present, {d} failed, {d} leftovers removed -> {s}/",
        .{ downloaded, reused, failures.items.len, pruned, options.directory },
    );
    if (failures.items.len > 0) {
        try host.report("failed: {s}", .{
            try std.mem.join(arena, ", ", failures.items[0..@min(10, failures.items.len)]),
        });
    }
}

fn primaryImage(record: *model.Enrichment) ?*model.Image {
    for (record.images) |*image| {
        if (image.primary) return @constCast(image);
    }
    return null;
}

/// A local copy under any of the known extensions.
fn existingCopy(host: Host, options: Options, slug: []const u8) !?[]const u8 {
    for (extensions) |suffix| {
        const filename = try std.fmt.allocPrint(host.arena, "{s}{s}", .{ slug, suffix });
        const path = try std.fs.path.join(host.arena, &.{ options.directory, filename });
        defer host.arena.free(path);
        host.root.access(host.io, path, .{}) catch continue;
        return filename;
    }
    return null;
}

/// Downloads, recompresses, and returns the filename written.
///
/// curl writes to a file and magick reads it back, rather than the two being
/// joined by a pipe. Driving both ends of a pipe from one thread deadlocks, and
/// a temporary file costs nothing here.
fn fetchLeaky(
    host: Host,
    arena: Allocator,
    options: Options,
    slug: []const u8,
    url: []const u8,
    existing: ?[]const u8,
) ![]const u8 {
    const scratch = try std.fs.path.join(arena, &.{ options.directory, ".download" });
    defer host.root.deleteFile(host.io, scratch) catch {};

    const probe = try host.runChecked(.{ .argv = &.{
        "curl",
        "--silent",
        "--show-error",
        "--location",
        "--max-time",
        std.fmt.comptimePrint("{d}", .{http.timeout_seconds}),
        "--user-agent",
        http.user_agent,
        "--output",
        scratch,
        "--write-out",
        "%{http_code} %{content_type} %{size_download}",
        url,
    } });
    defer probe.deinit(host.gpa);

    var fields = std.mem.tokenizeScalar(u8, probe.stdout, ' ');
    const status = std.fmt.parseUnsigned(u16, fields.next() orelse "0", 10) catch 0;
    const content_type = fields.next() orelse "";
    const size = std.fmt.parseUnsigned(u64, fields.next() orelse "0", 10) catch 0;

    if (status != 200) return error.HttpStatus;
    if (!std.mem.startsWith(u8, content_type, "image/")) return error.NotAnImage;
    if (size > maximum_bytes) return error.TooLarge;

    var suffix = extensionOf(url);
    var chosen = scratch;
    const compressed = try std.fs.path.join(arena, &.{ options.directory, ".compressed.jpg" });
    defer host.root.deleteFile(host.io, compressed) catch {};

    if (options.quality > 0) {
        const output = try host.runChecked(.{ .argv = &.{
            "magick",
            scratch,
            "-strip",
            "-interlace",
            "Plane",
            "-quality",
            try std.fmt.allocPrint(arena, "{d}", .{options.quality}),
            compressed,
        } });
        output.deinit(host.gpa);

        // Only worth it if it actually shrank: recompressing an already-small
        // JPEG can grow it.
        const stat = host.root.statFile(host.io, compressed, .{}) catch null;
        if (stat) |present| {
            if (present.size < size) {
                chosen = compressed;
                suffix = ".jpg";
            }
        }
    }

    const filename = try std.fmt.allocPrint(arena, "{s}{s}", .{ slug, suffix });
    const destination = try std.fs.path.join(arena, &.{ options.directory, filename });

    // A changed extension leaves the old file behind otherwise.
    if (existing) |previous| {
        if (!std.mem.eql(u8, previous, filename)) {
            const stale = try std.fs.path.join(arena, &.{ options.directory, previous });
            host.root.deleteFile(host.io, stale) catch {};
        }
    }
    try host.root.rename(chosen, host.root, destination, host.io);
    return filename;
}

fn extensionOf(url: []const u8) []const u8 {
    const without_query = url[0 .. std.mem.indexOfScalar(u8, url, '?') orelse url.len];
    const dot = std.mem.lastIndexOfScalar(u8, without_query, '.') orelse return ".jpg";
    const suffix = without_query[dot..];
    if (suffix.len > 5) return ".jpg";

    var lowered: [8]u8 = undefined;
    for (suffix, lowered[0..suffix.len]) |byte, *slot| slot.* = std.ascii.toLower(byte);
    for (extensions) |known| {
        if (std.mem.eql(u8, known, lowered[0..suffix.len])) return known;
    }
    return ".jpg";
}

/// On a full run, any image file no longer referenced is a leftover.
fn pruneOrphans(
    host: Host,
    arena: Allocator,
    options: Options,
    kept: []const []const u8,
    manifest: *std.json.ArrayHashMap(model.ImageCredit),
) !usize {
    var directory = try host.root.openDir(host.io, options.directory, .{ .iterate = true });
    defer directory.close(host.io);

    var stale: std.ArrayList([]const u8) = .empty;
    var entries = directory.iterate();
    while (try entries.next(host.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isImageName(entry.name)) continue;
        var known = false;
        for (kept) |name| known = known or std.mem.eql(u8, name, entry.name);
        if (!known) try stale.append(arena, try arena.dupe(u8, entry.name));
    }
    for (stale.items) |name| {
        const path = try std.fs.path.join(arena, &.{ options.directory, name });
        host.root.deleteFile(host.io, path) catch {};
        _ = manifest.map.orderedRemove(name);
    }
    return stale.items.len;
}

fn isImageName(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    var lowered: [8]u8 = undefined;
    const suffix = name[dot..];
    if (suffix.len > lowered.len) return false;
    for (suffix, lowered[0..suffix.len]) |byte, *slot| slot.* = std.ascii.toLower(byte);
    for (extensions) |known| {
        if (std.mem.eql(u8, known, lowered[0..suffix.len])) return true;
    }
    return false;
}

fn sortManifest(manifest: *std.json.ArrayHashMap(model.ImageCredit)) void {
    const Sorter = struct {
        keys: []const []const u8,
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return std.mem.lessThan(u8, self.keys[a], self.keys[b]);
        }
    };
    manifest.map.sort(Sorter{ .keys = manifest.map.keys() });
}

fn parseOptions(argv: []const []const u8) !Options {
    var options: Options = .{};
    var parser: cli.Parser = .init(argv);
    while (parser.next()) |token| switch (token) {
        .option => |option| {
            const name = option.name;
            if (std.mem.eql(u8, name, "enrichment")) {
                options.enrichment = try parser.value(option);
            } else if (std.mem.eql(u8, name, "source")) {
                options.source = try parser.value(option);
            } else if (std.mem.eql(u8, name, "merged")) {
                options.merged = try parser.value(option);
            } else if (std.mem.eql(u8, name, "limit")) {
                options.limit = try std.fmt.parseUnsigned(usize, try parser.value(option), 10);
            } else if (std.mem.eql(u8, name, "quality")) {
                options.quality = try std.fmt.parseUnsigned(u32, try parser.value(option), 10);
            } else if (std.mem.eql(u8, name, "force")) {
                options.force = true;
            } else {
                std.process.fatal("images: unknown option --{s}", .{name});
            }
        },
        .positional => |value| std.process.fatal("images: unexpected argument '{s}'", .{value}),
    };
    return options;
}

const testing_gpa = std.testing.allocator;

test "the extension comes from the URL, falling back to jpg" {
    try std.testing.expectEqualStrings(".jpg", extensionOf("https://x/a.jpg"));
    try std.testing.expectEqualStrings(".png", extensionOf("https://x/a.PNG"));
    try std.testing.expectEqualStrings(".webp", extensionOf("https://x/a.webp?width=500"));
    try std.testing.expectEqualStrings(".jpg", extensionOf("https://x/a.tiff"));
    try std.testing.expectEqualStrings(".jpg", extensionOf("https://x/no-extension"));
}

test "only known image extensions count as leftovers" {
    try std.testing.expect(isImageName("abies-concolor.jpg"));
    try std.testing.expect(isImageName("a.WEBP"));
    try std.testing.expect(!isImageName("credits.json"));
    try std.testing.expect(!isImageName("README"));
}
