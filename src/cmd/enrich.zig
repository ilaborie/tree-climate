//! `tree-climate enrich` — resolve taxa, descriptions and images from open
//! sources.
//!
//! Every text and every image is kept with its licence and its attribution, so
//! that what comes out can be published without borrowing anyone's work
//! silently. Runs against the disk cache by default, so a second run makes no
//! network call at all.

const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const csv = @import("../csv.zig");
const http = @import("../http.zig");
const json = @import("../json_util.zig");
const licence_policy = @import("../licence.zig");
const merge = @import("../merge.zig");
const model = @import("../model.zig");
const names = @import("../names.zig");
const net = @import("../net.zig");
const Host = @import("../host.zig").Host;

const schema_version = 1;
const wikipedia_attribution = "Contributeurs de Wikipédia";
const inat_photo_limit = 3;

const Options = struct {
    source: []const u8 = "data/data.json",
    output: []const u8 = "data/enrichment.json",
    merged: []const u8 = "data/species-enriched.json",
    translations: []const u8 = "data/translations.json",
    image_manifest: []const u8 = "img/credits.json",
    limit: ?usize = null,
    languages: []const []const u8 = &.{ "fr", "en" },
    /// Forbids every network call: only the cache is read.
    offline: bool = false,
    /// Overrides today's date, so a run can be reproduced exactly.
    generated_on: ?[]const u8 = null,
};

const references = [_]struct { key: []const u8, value: model.Reference }{
    .{ .key = "gbif", .value = .{
        .name = "GBIF Backbone Taxonomy",
        .url = "https://www.gbif.org",
        .licence = "CC BY 4.0",
        .usage = "résolution des noms et taxonomie",
    } },
    .{ .key = "wikidata", .value = .{
        .name = "Wikidata",
        .url = "https://www.wikidata.org",
        .licence = "CC0 1.0",
        .usage = "identifiants croisés et liens",
    } },
    .{ .key = "wikipedia", .value = .{
        .name = "Wikipédia",
        .url = "https://fr.wikipedia.org",
        .licence = "CC BY-SA 4.0",
        .usage = "descriptions",
    } },
    .{ .key = "commons", .value = .{
        .name = "Wikimedia Commons",
        .url = "https://commons.wikimedia.org",
        .licence = "par fichier",
        .usage = "images",
    } },
    .{ .key = "inaturalist", .value = .{
        .name = "iNaturalist",
        .url = "https://www.inaturalist.org",
        .licence = "par photo",
        .usage = "images de repli",
    } },
};

const licences = [_]struct { key: []const u8, value: model.Licence }{
    .{ .key = "cc0", .value = .{
        .name = "CC0 1.0",
        .url = "https://creativecommons.org/publicdomain/zero/1.0/",
        .attribution = false,
        .share_alike = false,
        .commercial = true,
    } },
    .{ .key = "domaine-public", .value = .{
        .name = "Domaine public",
        .url = "https://creativecommons.org/publicdomain/mark/1.0/",
        .attribution = false,
        .share_alike = false,
        .commercial = true,
    } },
    .{ .key = "cc-by", .value = .{
        .name = "CC BY",
        .url = "https://creativecommons.org/licenses/by/4.0/",
        .attribution = true,
        .share_alike = false,
        .commercial = true,
    } },
    .{ .key = "cc-by-sa", .value = .{
        .name = "CC BY-SA",
        .url = "https://creativecommons.org/licenses/by-sa/4.0/",
        .attribution = true,
        .share_alike = true,
        .commercial = true,
    } },
    .{ .key = "cc-by-nc", .value = .{
        .name = "CC BY-NC",
        .url = "https://creativecommons.org/licenses/by-nc/4.0/",
        .attribution = true,
        .share_alike = false,
        .commercial = false,
    } },
    .{ .key = "cc-by-nc-sa", .value = .{
        .name = "CC BY-NC-SA",
        .url = "https://creativecommons.org/licenses/by-nc-sa/4.0/",
        .attribution = true,
        .share_alike = true,
        .commercial = false,
    } },
};

/// Everything one species accumulates as the passes run.
const Work = struct {
    species: *const model.Species,
    targets: []const []const u8,
    taxon: ?model.Taxon = null,
    wikidata: ?net.WikidataRecord = null,
    wikidata_scope: net.Scope = .taxon_exact,
    descriptions: std.ArrayList(Described) = .empty,
    image_files: std.ArrayList(WantedImage) = .empty,
    images: []model.Image = &.{},
};

/// A description together with the file illustrating its article.
///
/// They travel as one value rather than as two parallel lists, because sorting
/// the descriptions used to leave the illustrations behind -- and the resulting
/// mismatch showed up only as a differently ordered image gallery.
const Described = struct {
    description: model.Description,
    illustration: ?[]const u8 = null,
};

const WantedImage = struct { title: []const u8, scope: net.Scope };

pub fn run(host: Host, argv: []const []const u8) !void {
    const options = try parseOptions(host.arena, argv);
    const arena = host.arena;

    const dataset = try json.readLeaky(
        model.Dataset,
        arena,
        host.io,
        host.root,
        options.source,
        .limited(16 << 20),
    );
    var species = dataset.species;
    if (options.limit) |limit| species = species[0..@min(limit, species.len)];

    var client: http.Client = .{
        .host = host,
        .cache = .{ .host = host },
        .offline = options.offline,
    };
    defer client.deinit();

    const work = try arena.alloc(Work, species.len);
    for (species, work) |*entry, *slot| {
        slot.* = .{ .species = entry, .targets = &.{} };
    }

    try host.report("-> taxonomic resolution of {d} species (GBIF)…", .{work.len});
    for (work) |*item| {
        item.taxon = net.gbifResolveLeaky(&client, arena, item.species.latin_name, null) catch null;
        item.targets = try net.targetsLeaky(arena, item.species.latin_name, item.taxon);
    }

    try host.report("-> cross identifiers (Wikidata)…", .{});
    try wikidataPass(&client, arena, work);

    try host.report("-> descriptions ({s})…", .{try std.mem.join(arena, ", ", options.languages)});
    try wikipediaPass(&client, arena, work, options.languages);
    try applyTranslations(host, arena, work, options);

    try host.report("-> images (Commons, then iNaturalist)…", .{});
    try imagePass(&client, arena, work, host, options);

    const enrichment = try assembleLeaky(host, arena, work, options);
    try json.writeAtomic(host.io, host.root, options.output, enrichment);
    try json.writeAtomic(host.io, host.root, options.merged, try merge.mergeLeaky(
        arena,
        dataset,
        species,
        enrichment,
    ));

    const directory = std.fs.path.dirname(options.output) orelse ".";
    try writeLinks(host, try std.fs.path.join(arena, &.{ directory, "species-links.csv" }), work);
    const unresolved = try writeUnresolved(
        host,
        try std.fs.path.join(arena, &.{ directory, "unresolved.csv" }),
        work,
    );

    const coverage = enrichment.coverage;
    try host.report(
        "{d} network calls, {d} cache reads, {d} absences, {d} failures",
        .{ client.counters.calls, client.counters.cache_hits, client.counters.absences, client.counters.failures },
    );
    try host.report("taxa resolved   : {d}/{d}", .{ coverage.taxon_resolved, coverage.total });
    try host.report("with description: {d} (of which {d} in French)", .{
        coverage.with_description,
        coverage.french_description,
    });
    try host.report("with image      : {d}", .{coverage.with_image});
    try host.report("with neither    : {d}", .{coverage.with_neither});
    try host.report("{s} · {s} ({d} unresolved)", .{ options.output, options.merged, unresolved });
}

// -------------------------------------------------------------------- passes

fn wikidataPass(client: *http.Client, arena: Allocator, work: []Work) !void {
    var wanted: std.ArrayList([]const u8) = .empty;
    for (work) |item| {
        for (item.targets) |target| try appendUnique(arena, &wanted, target);
    }
    std.mem.sort([]const u8, wanted.items, {}, lessThanString);

    const records = net.wikidataByNamesLeaky(client, arena, wanted.items) catch
        std.StringArrayHashMapUnmanaged(net.WikidataRecord).empty;

    for (work) |*item| {
        for (item.targets) |target| {
            if (records.get(target)) |record| {
                item.wikidata = record;
                item.wikidata_scope = scopeOf(arena, item.species.latin_name, target, item.taxon);
                break;
            }
        }
    }
}

fn wikipediaPass(
    client: *http.Client,
    arena: Allocator,
    work: []Work,
    languages: []const []const u8,
) !void {
    for (languages) |language| {
        var candidates = try arena.alloc([]const TitleCandidate, work.len);
        var wanted: std.ArrayList([]const u8) = .empty;
        for (work, 0..) |item, at| {
            candidates[at] = try titleCandidatesLeaky(arena, item, language);
            for (candidates[at]) |candidate| try appendUnique(arena, &wanted, candidate.title);
        }
        std.mem.sort([]const u8, wanted.items, {}, lessThanString);

        const summaries = net.wikipediaSummariesLeaky(client, arena, wanted.items, language) catch
            continue;

        for (work, candidates) |*item, list| {
            for (list) |candidate| {
                const summary = summaries.get(candidate.title) orelse continue;
                try item.descriptions.append(arena, .{
                    .description = .{
                        .language = summary.language,
                        .page_title = summary.page_title,
                        .text = summary.text,
                        .url = summary.url,
                        .source = "wikipedia",
                        .licence = "cc-by-sa",
                        .attribution = wikipedia_attribution,
                        .scope = candidate.scope.name(),
                    },
                    .illustration = summary.image_file,
                });
                break;
            }
        }
    }
    for (work) |*item| orderDescriptions(item, languages);
}

const TitleCandidate = struct { title: []const u8, scope: net.Scope };

/// Article titles to try, most precise first.
fn titleCandidatesLeaky(arena: Allocator, item: Work, language: []const u8) ![]const TitleCandidate {
    var list: std.ArrayList(TitleCandidate) = .empty;
    if (item.wikidata) |record| {
        const url = if (std.mem.eql(u8, language, "fr")) record.frwiki else record.enwiki;
        if (url) |present| {
            if (try titleFromUrlLeaky(arena, present)) |title| {
                try list.append(arena, .{ .title = title, .scope = item.wikidata_scope });
            }
        }
    }
    for (item.targets) |target| {
        try list.append(arena, .{
            .title = target,
            .scope = scopeOf(arena, item.species.latin_name, target, item.taxon),
        });
    }

    var kept: std.ArrayList(TitleCandidate) = .empty;
    for (list.items) |candidate| {
        if (candidate.title.len == 0) continue;
        var known = false;
        for (kept.items) |already| known = known or std.mem.eql(u8, already.title, candidate.title);
        if (!known) try kept.append(arena, candidate);
    }
    return kept.items;
}

/// A more precise record goes first, then the more expected language.
fn orderDescriptions(item: *Work, languages: []const []const u8) void {
    const Sorter = struct {
        languages: []const []const u8,
        fn before(self: @This(), a: Described, b: Described) bool {
            const a_scope = scopeFromName(a.description.scope).precision();
            const b_scope = scopeFromName(b.description.scope).precision();
            if (a_scope != b_scope) return a_scope < b_scope;
            return self.rank(a.description.language) < self.rank(b.description.language);
        }
        fn rank(self: @This(), language: []const u8) usize {
            for (self.languages, 0..) |known, at| {
                if (std.mem.eql(u8, known, language)) return at;
            }
            return self.languages.len;
        }
    };
    std.mem.sort(
        Described,
        item.descriptions.items,
        Sorter{ .languages = languages },
        Sorter.before,
    );
}

/// Adds a translated French description where only a foreign text exists.
///
/// A translation is a derivative work: it stays under the licence of the source
/// article, whose title and URL are kept in `translated_from` so the credit
/// points at what was actually translated.
fn applyTranslations(host: Host, arena: Allocator, work: []Work, options: Options) !void {
    const translations = json.readForeignLeaky(
        std.json.ArrayHashMap([]const u8),
        arena,
        host.io,
        host.root,
        options.translations,
        .limited(4 << 20),
    ) catch return;

    var used: usize = 0;
    for (work) |*item| {
        const text = translations.map.get(item.species.latin_name) orelse continue;
        const foreign = for (item.descriptions.items) |entry| {
            if (!std.mem.eql(u8, entry.description.language, "fr")) break entry.description;
        } else continue;

        used += 1;
        try item.descriptions.append(arena, .{ .description = .{
            .language = "fr",
            .page_title = foreign.page_title,
            .text = text,
            .url = foreign.url,
            .source = foreign.source,
            .licence = foreign.licence,
            .attribution = wikipedia_attribution ++ ", traduction française",
            .scope = foreign.scope,
            .translated_from = .{
                .language = foreign.language,
                .page_title = foreign.page_title,
                .url = foreign.url,
            },
        } });
        orderDescriptions(item, options.languages);
    }
    if (used < translations.map.count()) {
        try host.report("   ! {d} translations match no species", .{translations.map.count() - used});
    }
}

fn imagePass(
    client: *http.Client,
    arena: Allocator,
    work: []Work,
    host: Host,
    options: Options,
) !void {
    const local = try localImagesLeaky(host, arena, options);

    var wanted: std.ArrayList([]const u8) = .empty;
    for (work) |*item| {
        // Descriptions come first and in order: the article illustrating the
        // most precise description is the most likely to show the right plant.
        for (item.descriptions.items) |entry| {
            const file = entry.illustration orelse continue;
            try appendWanted(arena, item, file, scopeFromName(entry.description.scope));
        }
        if (item.wikidata) |record| {
            for (record.images) |url| {
                const decoded = try percentDecodeLeaky(arena, lastSegment(url));
                try appendWanted(arena, item, decoded, item.wikidata_scope);
            }
        }
        for (item.image_files.items) |file| try appendUnique(arena, &wanted, file.title);
    }
    std.mem.sort([]const u8, wanted.items, {}, lessThanString);

    const metadata = net.commonsFilesLeaky(client, arena, wanted.items) catch
        std.StringArrayHashMapUnmanaged(model.Image).empty;

    for (work) |*item| {
        var kept: std.ArrayList(model.Image) = .empty;
        for (item.image_files.items) |file| {
            var image = metadata.get(file.title) orelse continue;
            image.scope = file.scope.name();
            if (isUsable(image)) try kept.append(arena, image);
        }
        if (kept.items.len == 0 and item.targets.len > 0) {
            const target = item.targets[0];
            const scope = scopeOf(arena, item.species.latin_name, target, item.taxon);
            const photos = net.inatPhotosLeaky(
                client,
                arena,
                target,
                &licence_policy.accepted,
                inat_photo_limit,
            ) catch &.{};
            for (photos) |photo| {
                var image = photo;
                image.scope = scope.name();
                if (isUsable(image)) try kept.append(arena, image);
            }
        }

        std.mem.sort(model.Image, kept.items, {}, byPrecision);
        if (kept.items.len > 0) {
            kept.items[0].primary = true;
            // A copy already downloaded survives a re-run.
            if (local.get(item.species.latin_name)) |path| {
                kept.items[0].local_file = path;
            }
        }
        item.images = kept.items;
    }
}

fn appendWanted(arena: Allocator, item: *Work, filename: []const u8, scope: net.Scope) !void {
    const title = try std.mem.concat(arena, u8, &.{ "File:", filename });
    for (item.image_files.items) |existing| {
        if (std.mem.eql(u8, existing.title, title)) return;
    }
    try item.image_files.append(arena, .{ .title = title, .scope = scope });
}

/// Hard filter: an accepted licence, and an identifiable author whenever
/// attribution is due. Nothing else may be published.
fn isUsable(image: model.Image) bool {
    if (!licence_policy.isAccepted(image.licence) or image.url.len == 0) return false;
    if (image.author.len > 0) return true;
    for (licences) |entry| {
        if (std.mem.eql(u8, entry.key, image.licence)) return !entry.value.attribution;
    }
    return false;
}

fn byPrecision(_: void, a: model.Image, b: model.Image) bool {
    return scopeFromName(a.scope).precision() < scopeFromName(b.scope).precision();
}

/// {latin name: local path} from the manifest the image downloader writes.
fn localImagesLeaky(
    host: Host,
    arena: Allocator,
    options: Options,
) !std.StringArrayHashMapUnmanaged([]const u8) {
    var paths: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    const manifest = json.readLeaky(
        std.json.ArrayHashMap(model.ImageCredit),
        arena,
        host.io,
        host.root,
        options.image_manifest,
        .limited(8 << 20),
    ) catch return paths;

    var entries = manifest.map.iterator();
    while (entries.next()) |entry| {
        const path = try std.fmt.allocPrint(arena, "img/{s}", .{entry.key_ptr.*});
        host.root.access(host.io, path, .{}) catch continue;
        try paths.put(arena, entry.value_ptr.latin_name, path);
    }
    return paths;
}

// ----------------------------------------------------------------- assembling

fn assembleLeaky(
    host: Host,
    arena: Allocator,
    work: []Work,
    options: Options,
) !model.EnrichmentDataset {
    var records: std.json.ArrayHashMap(model.Enrichment) = .{};
    const ordered = try arena.dupe(Work, work);
    std.mem.sort(Work, ordered, {}, byLatinName);

    var coverage: model.Coverage = .{
        .total = @intCast(work.len),
        .with_description = 0,
        .french_description = 0,
        .with_image = 0,
        .with_both = 0,
        .with_neither = 0,
        .taxon_resolved = 0,
        .fallback_parent_species = 0,
        .fallback_genus = 0,
        .exact_match = 0,
    };

    for (ordered) |item| {
        const has_description = item.descriptions.items.len > 0;
        const has_image = item.images.len > 0;
        if (has_description) coverage.with_description += 1;
        if (has_image) coverage.with_image += 1;
        if (has_description and has_image) coverage.with_both += 1;
        if (!has_description and !has_image) coverage.with_neither += 1;
        for (item.descriptions.items) |entry| {
            if (std.mem.eql(u8, entry.description.language, "fr")) {
                coverage.french_description += 1;
                break;
            }
        }
        if (item.taxon) |taxon| {
            coverage.taxon_resolved += 1;
            if (std.mem.eql(u8, taxon.fallback_level, "exact")) coverage.exact_match += 1;
            if (std.mem.eql(u8, taxon.fallback_level, "genre")) coverage.fallback_genus += 1;
            if (std.mem.eql(u8, taxon.fallback_level, "espece_parente")) {
                coverage.fallback_parent_species += 1;
            }
        }

        try records.map.put(arena, item.species.latin_name, .{
            .normalised_name = try names.normaliseLeaky(arena, item.species.latin_name),
            .estimated_rank = names.estimatedRank(item.species.latin_name).name(),
            .taxon = item.taxon,
            .identifiers = try identifiersLeaky(arena, item),
            .wikidata_vernacular_name = if (item.wikidata) |record| record.french_label else null,
            .descriptions = try descriptionsLeaky(arena, item),
            .images = item.images,
            .links = try linksLeaky(arena, item),
            .warnings = try warningsLeaky(arena, item),
        });
    }

    return .{
        .generated_on = options.generated_on orelse try todayLeaky(arena, host),
        .schema_version = schema_version,
        .references = try referenceMapLeaky(arena),
        .licences = try licenceMapLeaky(arena),
        .coverage = coverage,
        .species = records,
    };
}

fn descriptionsLeaky(arena: Allocator, item: Work) ![]const model.Description {
    const plain = try arena.alloc(model.Description, item.descriptions.items.len);
    for (item.descriptions.items, plain) |entry, *slot| slot.* = entry.description;
    return plain;
}

fn identifiersLeaky(arena: Allocator, item: Work) !std.json.ArrayHashMap([]const u8) {
    var pairs: std.ArrayList(net.Identifier) = .empty;
    if (item.wikidata) |record| {
        for (record.identifiers) |identifier| try pairs.append(arena, identifier);
        if (record.qid.len > 0) try pairs.append(arena, .{ .key = "wikidata", .value = record.qid });
    }
    if (item.taxon) |taxon| {
        try pairs.append(arena, .{
            .key = "gbif",
            .value = try std.fmt.allocPrint(arena, "{d}", .{taxon.gbif_key}),
        });
    }
    std.mem.sort(net.Identifier, pairs.items, {}, lessThanIdentifier);

    var map: std.json.ArrayHashMap([]const u8) = .{};
    for (pairs.items) |pair| try map.map.put(arena, pair.key, pair.value);
    return map;
}

fn linksLeaky(arena: Allocator, item: Work) ![]const model.Link {
    var links: std.ArrayList(model.Link) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;

    for (item.descriptions.items) |entry| {
        const description = entry.description;
        // A translation links to the article it came from, not to a French one.
        const language = if (description.translated_from) |origin| origin.language else description.language;
        const url = if (description.translated_from) |origin| origin.url else description.url;
        var known = false;
        for (seen.items) |already| known = known or std.mem.eql(u8, already, url);
        if (known) continue;
        try seen.append(arena, url);
        try links.append(arena, .{
            .label = try std.fmt.allocPrint(arena, "Wikipédia ({s})", .{language}),
            .url = url,
            .publisher = "Wikipédia",
        });
    }
    if (item.taxon) |taxon| {
        try links.append(arena, .{
            .label = "Fiche GBIF",
            .url = try std.fmt.allocPrint(arena, "https://www.gbif.org/species/{d}", .{taxon.gbif_key}),
            .publisher = "GBIF",
        });
    }
    if (item.wikidata) |record| {
        try links.append(arena, .{
            .label = "Wikidata",
            .url = try std.fmt.allocPrint(arena, "https://www.wikidata.org/wiki/{s}", .{record.qid}),
            .publisher = "Wikidata",
        });
        for (record.identifiers) |identifier| {
            if (std.mem.eql(u8, identifier.key, "inaturalist")) try links.append(arena, .{
                .label = "iNaturalist",
                .url = try std.fmt.allocPrint(arena, "https://www.inaturalist.org/taxa/{s}", .{identifier.value}),
                .publisher = "iNaturalist",
            });
        }
        for (record.identifiers) |identifier| {
            if (std.mem.eql(u8, identifier.key, "tela_botanica")) try links.append(arena, .{
                .label = "Tela Botanica",
                .url = try std.fmt.allocPrint(
                    arena,
                    "https://www.tela-botanica.org/bdtfx-nn-{s}",
                    .{identifier.value},
                ),
                .publisher = "Tela Botanica",
            });
        }
        for (record.identifiers) |identifier| {
            if (std.mem.eql(u8, identifier.key, "commons")) try links.append(arena, .{
                .label = "Wikimedia Commons",
                .url = try std.fmt.allocPrint(
                    arena,
                    "https://commons.wikimedia.org/wiki/Category:{s}",
                    .{try urlQuoteLeaky(arena, identifier.value)},
                ),
                .publisher = "Wikimedia Commons",
            });
        }
    }
    return links.items;
}

/// Flags any datum that describes a relative rather than the taxon asked for.
fn warningsLeaky(arena: Allocator, item: Work) ![]const []const u8 {
    var messages: std.ArrayList([]const u8) = .empty;
    const taxon = item.taxon orelse {
        try messages.append(arena, "nom non résolu sur GBIF");
        return messages.items;
    };

    const first_description: ?[]const u8 = if (item.descriptions.items.len > 0)
        item.descriptions.items[0].description.scope
    else
        null;
    const first_image: ?[]const u8 = if (item.images.len > 0) item.images[0].scope else null;

    for ([_]struct { scope: ?[]const u8, label: []const u8 }{
        .{ .scope = first_description, .label = "description" },
        .{ .scope = first_image, .label = "image" },
    }) |subject| {
        const scope = subject.scope orelse continue;
        if (std.mem.eql(u8, scope, "genre")) {
            try messages.append(arena, try std.fmt.allocPrint(
                arena,
                "{s} du genre {s}, pas de « {s} »",
                .{ subject.label, taxon.genus, item.species.latin_name },
            ));
        } else if (std.mem.eql(u8, scope, "espece_parente")) {
            try messages.append(arena, try std.fmt.allocPrint(
                arena,
                "{s} de l'espèce {s}, pas du taxon « {s} »",
                .{ subject.label, taxon.species orelse taxon.canonical_name, item.species.latin_name },
            ));
        }
    }
    return messages.items;
}

// ------------------------------------------------------------------- outputs

fn writeLinks(host: Host, path: []const u8, work: []const Work) !void {
    const ordered = try host.arena.dupe(Work, work);
    std.mem.sort(Work, ordered, {}, byLatinName);

    var atomic = try host.root.createFileAtomic(host.io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(host.io);
    var buffer: [64 * 1024]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, host.io, &buffer);
    var out: csv.Writer = .{ .out = &file.interface };

    try out.fields(&.{
        "latin_name",    "canonical_name", "family",   "wikidata",
        "gbif",          "wikipedia_url",  "language", "image_url",
        "image_licence", "image_author",
    });
    try out.endRow();

    for (ordered) |item| {
        const description: ?model.Description = if (item.descriptions.items.len > 0)
            item.descriptions.items[0].description
        else
            null;
        const image: ?model.Image = if (item.images.len > 0) item.images[0] else null;

        try out.field(item.species.latin_name);
        try out.field(if (item.taxon) |taxon| taxon.canonical_name else "");
        try out.field(if (item.taxon) |taxon| taxon.family else "");
        try out.field(if (item.wikidata) |record| record.qid else "");
        try out.field(if (item.taxon) |taxon|
            try std.fmt.allocPrint(host.arena, "{d}", .{taxon.gbif_key})
        else
            "");
        try out.field(if (description) |present| present.url else "");
        try out.field(if (description) |present| present.language else "");
        try out.field(if (image) |present| present.url else "");
        try out.field(if (image) |present| present.licence else "");
        try out.field(if (image) |present| present.author else "");
        try out.endRow();
    }
    try file.interface.flush();
    try atomic.replace(host.io);
}

fn writeUnresolved(host: Host, path: []const u8, work: []const Work) !usize {
    const ordered = try host.arena.dupe(Work, work);
    std.mem.sort(Work, ordered, {}, byLatinName);

    var atomic = try host.root.createFileAtomic(host.io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(host.io);
    var buffer: [64 * 1024]u8 = undefined;
    var file: std.Io.File.Writer = .init(atomic.file, host.io, &buffer);
    var out: csv.Writer = .{ .out = &file.interface, .delimiter = ';' };

    try out.fields(&.{ "latin_name", "search_name", "reasons", "comment" });
    try out.endRow();

    var written: usize = 0;
    for (ordered) |item| {
        var reasons: std.ArrayList([]const u8) = .empty;
        defer reasons.deinit(host.arena);
        if (item.taxon == null) try reasons.append(host.arena, "taxon_not_found");
        if (item.descriptions.items.len == 0) try reasons.append(host.arena, "no_description");
        if (item.images.len == 0) try reasons.append(host.arena, "no_image");
        if (reasons.items.len == 0) continue;

        written += 1;
        try out.field(item.species.latin_name);
        try out.field("");
        try out.joined(host.arena, reasons.items);
        try out.field("");
        try out.endRow();
    }
    try file.interface.flush();
    try atomic.replace(host.io);
    return written;
}

// -------------------------------------------------------------------- helpers

/// Says whether a record found under `target` describes the species, or a parent.
fn scopeOf(
    arena: Allocator,
    latin_name: []const u8,
    target: []const u8,
    taxon: ?model.Taxon,
) net.Scope {
    const cascade = names.candidatesLeaky(arena, latin_name) catch return .espece_parente;
    const full = if (cascade.len > 0) cascade[0] else latin_name;

    if (sameTaxon(arena, target, full)) {
        const genus_only = countWords(target) == 1;
        const rank = names.estimatedRank(latin_name);
        const loose = rank == .cultivar or rank == .hybride;
        return if (genus_only and loose) .genre else .taxon_exact;
    }
    if (taxon) |present| {
        if (std.mem.eql(u8, target, present.genus)) return .genre;
    }
    return .espece_parente;
}

/// "Platanus × hispanica" and "Platanus x hispanica" name the same taxon.
fn sameTaxon(arena: Allocator, a: []const u8, b: []const u8) bool {
    const left = withoutHybridMarker(arena, a) catch return false;
    const right = withoutHybridMarker(arena, b) catch return false;
    return asciiEqualFold(left, right);
}

fn withoutHybridMarker(arena: Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = value;
    while (rest.len > 0) {
        if (std.mem.startsWith(u8, rest, "\u{00D7} ")) {
            rest = rest["\u{00D7} ".len..];
            continue;
        }
        if (std.mem.startsWith(u8, rest, "x ")) {
            rest = rest["x ".len..];
            continue;
        }
        try out.append(arena, rest[0]);
        rest = rest[1..];
    }
    return out.items;
}

fn scopeFromName(name: []const u8) net.Scope {
    return std.meta.stringToEnum(net.Scope, name) orelse .espece_parente;
}

fn titleFromUrlLeaky(arena: Allocator, url: []const u8) !?[]const u8 {
    if (url.len == 0) return null;
    const decoded = try percentDecodeLeaky(arena, lastSegment(url));
    const title = try arena.dupe(u8, decoded);
    for (title) |*byte| {
        if (byte.* == '_') byte.* = ' ';
    }
    return title;
}

fn percentDecodeLeaky(arena: Allocator, value: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, '%') == null) return value;
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < value.len) {
        if (value[at] == '%' and at + 2 < value.len) {
            const byte = std.fmt.parseUnsigned(u8, value[at + 1 .. at + 3], 16) catch {
                try out.append(arena, value[at]);
                at += 1;
                continue;
            };
            try out.append(arena, byte);
            at += 3;
            continue;
        }
        try out.append(arena, value[at]);
        at += 1;
    }
    return out.items;
}

fn urlQuoteLeaky(arena: Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~', '/' => try out.append(arena, byte),
        ' ' => try out.append(arena, '_'),
        else => try out.print(arena, "%{X:0>2}", .{byte}),
    };
    return out.items;
}

fn todayLeaky(arena: Allocator, host: Host) ![]const u8 {
    const nanoseconds = std.Io.Timestamp.now(host.io, .real).nanoseconds;
    const seconds: u64 = @intCast(@divTrunc(nanoseconds, std.time.ns_per_s));
    const day = (std.time.epoch.EpochSeconds{ .secs = seconds }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
    });
}

fn referenceMapLeaky(arena: Allocator) !std.json.ArrayHashMap(model.Reference) {
    var map: std.json.ArrayHashMap(model.Reference) = .{};
    for (references) |entry| try map.map.put(arena, entry.key, entry.value);
    return map;
}

fn licenceMapLeaky(arena: Allocator) !std.json.ArrayHashMap(model.Licence) {
    var map: std.json.ArrayHashMap(model.Licence) = .{};
    for (licences) |entry| try map.map.put(arena, entry.key, entry.value);
    return map;
}

fn byLatinName(_: void, a: Work, b: Work) bool {
    return std.mem.lessThan(u8, a.species.latin_name, b.species.latin_name);
}

fn lessThanString(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanIdentifier(_: void, a: net.Identifier, b: net.Identifier) bool {
    return std.mem.lessThan(u8, a.key, b.key);
}

fn appendUnique(arena: Allocator, list: *std.ArrayList([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try list.append(arena, value);
}

fn asciiEqualFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn countWords(value: []const u8) usize {
    var pieces = std.mem.tokenizeScalar(u8, value, ' ');
    var total: usize = 0;
    while (pieces.next()) |_| total += 1;
    return total;
}

fn lastSegment(url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return url;
    return url[slash + 1 ..];
}

fn parseOptions(arena: Allocator, argv: []const []const u8) !Options {
    var options: Options = .{};
    var parser: cli.Parser = .init(argv);
    while (parser.next()) |token| switch (token) {
        .option => |option| {
            const name = option.name;
            if (std.mem.eql(u8, name, "source")) {
                options.source = try parser.value(option);
            } else if (std.mem.eql(u8, name, "out")) {
                options.output = try parser.value(option);
            } else if (std.mem.eql(u8, name, "merged")) {
                options.merged = try parser.value(option);
            } else if (std.mem.eql(u8, name, "limit")) {
                options.limit = try std.fmt.parseUnsigned(usize, try parser.value(option), 10);
            } else if (std.mem.eql(u8, name, "offline")) {
                options.offline = true;
            } else if (std.mem.eql(u8, name, "generated-on")) {
                options.generated_on = try parser.value(option);
            } else if (std.mem.eql(u8, name, "languages")) {
                var list: std.ArrayList([]const u8) = .empty;
                var pieces = std.mem.tokenizeScalar(u8, try parser.value(option), ',');
                while (pieces.next()) |piece| try list.append(arena, piece);
                options.languages = list.items;
            } else {
                std.process.fatal("enrich: unknown option --{s}", .{name});
            }
        },
        .positional => |value| std.process.fatal("enrich: unexpected argument '{s}'", .{value}),
    };
    return options;
}
