//! Adapters over the open databases the enrichment queries: GBIF, Wikidata,
//! Wikipedia, Commons, iNaturalist.
//!
//! Each returns cleaned-up records; politeness, retries and caching are the
//! client's job. They live together because they share one thing that is hard
//! to get right -- per-key memoisation over APIs that answer in batches -- and
//! splitting them would mean five copies of it or an abstraction with one user.

const std = @import("std");
const Allocator = std.mem.Allocator;
const http = @import("http.zig");
const licence_policy = @import("licence.zig");
const model = @import("model.zig");
const names = @import("names.zig");
const xml = @import("pdf/xml.zig");

const gbif_match = "https://api.gbif.org/v1/species/match";
const wikidata_sparql = "https://query.wikidata.org/sparql";
const commons_api = "https://commons.wikimedia.org/w/api.php";
const inaturalist = "https://api.inaturalist.org/v1/observations";

const minimum_confidence = 80;

/// Above genus a match tells us nothing about the species: GBIF answers
/// "Plantae" or "Rosaceae" where it does not recognise a name, and the sheet
/// would then describe plants in general. Better to drop a rung down the
/// fallback cascade.
const useful_ranks = [_][]const u8{ "SPECIES", "SUBSPECIES", "VARIETY", "FORM", "GENUS" };

/// prop=extracts caps at 20 extracts per request, however many titles are asked
/// for. Asking for 50 would silently truncate.
pub const extracts_per_request = 20;
pub const titles_per_request = 50;

/// Commons only serves a fixed set of thumbnail widths and returns the matching
/// URL; it must be used verbatim, since a hand-built one is refused (HTTP 400).
const thumbnail_width = 500;

pub const Scope = enum {
    taxon_exact,
    espece_parente,
    genre,

    pub fn name(self: Scope) []const u8 {
        return @tagName(self);
    }

    /// A sheet describing the taxon asked for beats one describing its species
    /// or its genus, ahead of any language preference: better the species in
    /// English than the genus in French.
    pub fn precision(self: Scope) u8 {
        return switch (self) {
            .taxon_exact => 0,
            .espece_parente => 1,
            .genre => 2,
        };
    }
};

// ------------------------------------------------------------------- batching

/// Memoises individual keys served by an API that answers in batches.
///
/// The subtlety is what happens to a key the batch did not return: it is
/// written back as absent, so the next run does not ask again.
fn batchedCacheLeaky(
    client: *http.Client,
    arena: Allocator,
    source: []const u8,
    keys: []const []const u8,
    batch_size: usize,
    kind: Batch,
) !std.StringArrayHashMapUnmanaged(std.json.Value) {
    var found: std.StringArrayHashMapUnmanaged(std.json.Value) = .empty;
    var missing: std.ArrayList([]const u8) = .empty;

    for (keys) |key| {
        if (try client.cache.readLeaky(arena, source, key)) |entry| {
            client.counters.cache_hits += 1;
            switch (entry) {
                .absent => {},
                .present => |value| try found.put(arena, key, value),
            }
        } else {
            try missing.append(arena, key);
        }
    }
    if (missing.items.len == 0) return found;
    if (client.offline) {
        std.log.warn("{d} keys missing from the {s} cache while offline", .{
            missing.items.len,
            source,
        });
        return http.Error.Unreachable;
    }

    var at: usize = 0;
    while (at < missing.items.len) : (at += batch_size) {
        const batch = missing.items[at..@min(at + batch_size, missing.items.len)];
        const answers = try kind.fetchLeaky(client, arena, batch);
        for (batch) |key| {
            const value = answers.get(key);
            try client.cache.write(source, key, value);
            if (value) |present| try found.put(arena, key, present);
        }
    }
    return found;
}

const Batch = union(enum) {
    wikidata,
    wikipedia: []const u8,
    commons,

    fn fetchLeaky(
        self: Batch,
        client: *http.Client,
        arena: Allocator,
        batch: []const []const u8,
    ) !std.StringArrayHashMapUnmanaged(std.json.Value) {
        return switch (self) {
            .wikidata => wikidataBatchLeaky(client, arena, batch),
            .wikipedia => |language| wikipediaBatchLeaky(client, arena, batch, language),
            .commons => commonsBatchLeaky(client, arena, batch),
        };
    }
};

// ----------------------------------------------------------------------- GBIF

/// Resolves a name from the PDF against GBIF, walking the fallback cascade.
pub fn gbifResolveLeaky(
    client: *http.Client,
    arena: Allocator,
    latin_name: []const u8,
    forced: ?[]const u8,
) !?model.Taxon {
    const cascade = if (forced) |name|
        try arena.dupe([]const u8, &.{name})
    else
        try names.candidatesLeaky(arena, latin_name);

    for (cascade) |candidate| {
        // Without the kingdom, genera that share a name with an animal genus
        // (Ulmus and friends) stay ambiguous.
        const answer = try client.cachedLeaky(arena, "gbif", candidate, gbif_match, &.{
            .{ .name = "name", .value = candidate },
            .{ .name = "kingdom", .value = "Plantae" },
        }, .get) orelse continue;
        if (answer != .object) continue;
        const match = answer.object;

        const match_type = stringField(match, "matchType") orelse continue;
        if (std.mem.eql(u8, match_type, "NONE")) continue;
        if (integerField(match, "confidence") orelse 0 < minimum_confidence) continue;
        const usage_key = integerField(match, "usageKey") orelse continue;
        const rank = stringField(match, "rank") orelse continue;
        if (!isOneOf(rank, &useful_ranks)) continue;

        return .{
            .source = "gbif",
            .queried_name = candidate,
            .gbif_key = @intCast(usage_key),
            .canonical_name = stringField(match, "canonicalName") orelse "",
            .scientific_name = stringField(match, "scientificName") orelse "",
            .rank = rank,
            .status = stringField(match, "status") orelse "",
            .confidence = @intCast(integerField(match, "confidence") orelse 0),
            .match_type = match_type,
            .kingdom = stringField(match, "kingdom") orelse "",
            .class = stringField(match, "class") orelse "",
            .order = stringField(match, "order") orelse "",
            .family = stringField(match, "family") orelse "",
            .genus = stringField(match, "genus") orelse "",
            .species = stringField(match, "species"),
            .fallback_level = try fallbackLevel(arena, latin_name, candidate, match),
        };
    }
    return null;
}

/// Says whether the record found describes the taxon asked for, or a parent.
fn fallbackLevel(
    arena: Allocator,
    latin_name: []const u8,
    candidate: []const u8,
    match: std.json.ObjectMap,
) ![]const u8 {
    const source_rank = names.estimatedRank(latin_name);
    const canonical = stringField(match, "canonicalName") orelse "";

    var significant: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, candidate, ' ');
    while (words.next()) |word| {
        if (!std.mem.eql(u8, word, "x")) try significant.append(arena, word);
    }

    if (std.mem.eql(u8, stringField(match, "rank") orelse "", "GENUS")) {
        return if (source_rank == .genre) "exact" else "genre";
    }
    const joined = try std.mem.join(arena, " ", significant.items);
    if (asciiEqualFold(canonical, joined)) return "exact";
    if (std.mem.eql(u8, stringField(match, "matchType") orelse "", "FUZZY") and
        countWords(canonical) == significant.items.len) return "exact";
    return "espece_parente";
}

/// Names to query on Wikidata and Wikipedia, most precise first.
///
/// The PDF's own name comes first: encyclopedias often keep the old name as a
/// redirect where GBIF has already reclassified the taxon (Sorbus latifolia to
/// Karpatiosorbus).
pub fn targetsLeaky(
    arena: Allocator,
    latin_name: []const u8,
    taxon: ?model.Taxon,
) ![]const []const u8 {
    var proposals: std.ArrayList([]const u8) = .empty;
    const cascade = try names.candidatesLeaky(arena, latin_name);
    if (cascade.len > 0) try proposals.append(arena, cascade[0]);
    if (taxon) |present| {
        try proposals.append(arena, present.canonical_name);
        if (present.species) |species| try proposals.append(arena, species);
        try proposals.append(arena, present.genus);
    }

    var kept: std.ArrayList([]const u8) = .empty;
    for (proposals.items) |proposal| {
        if (proposal.len == 0) continue;
        try appendUnique(arena, &kept, proposal);
        // Wikidata and Wikipedia spell hybrids with the multiplication sign,
        // not with an x.
        if (std.mem.indexOf(u8, proposal, " x ") != null) {
            const size = std.mem.replacementSize(u8, proposal, " x ", " \u{00D7} ");
            const variant = try arena.alloc(u8, size);
            _ = std.mem.replace(u8, proposal, " x ", " \u{00D7} ", variant);
            try appendUnique(arena, &kept, variant);
        }
    }
    return kept.items;
}

// ------------------------------------------------------------------- Wikidata

pub const WikidataRecord = struct {
    qid: []const u8,
    images: []const []const u8,
    identifiers: []const Identifier,
    french_label: ?[]const u8 = null,
    frwiki: ?[]const u8 = null,
    enwiki: ?[]const u8 = null,
};

pub const Identifier = struct { key: []const u8, value: []const u8 };

const taxon_query =
    \\SELECT ?nom ?item ?image ?gbif ?inat ?tela ?commons ?frwiki ?enwiki ?libelle WHERE {
    \\  VALUES ?nom { %s }
    \\  ?item wdt:P225 ?nom .
    \\  OPTIONAL { ?item wdt:P18 ?image }
    \\  OPTIONAL { ?item wdt:P846 ?gbif }
    \\  OPTIONAL { ?item wdt:P3151 ?inat }
    \\  OPTIONAL { ?item wdt:P3591 ?tela }
    \\  OPTIONAL { ?item wdt:P373 ?commons }
    \\  OPTIONAL { ?frwiki schema:about ?item ; schema:isPartOf <https://fr.wikipedia.org/> }
    \\  OPTIONAL { ?enwiki schema:about ?item ; schema:isPartOf <https://en.wikipedia.org/> }
    \\  OPTIONAL { ?item rdfs:label ?libelle FILTER(lang(?libelle) = "fr") }
    \\}
;

pub fn wikidataByNamesLeaky(
    client: *http.Client,
    arena: Allocator,
    canonical_names: []const []const u8,
) !std.StringArrayHashMapUnmanaged(WikidataRecord) {
    const raw = try batchedCacheLeaky(
        client,
        arena,
        "wikidata",
        canonical_names,
        titles_per_request,
        .wikidata,
    );

    var records: std.StringArrayHashMapUnmanaged(WikidataRecord) = .empty;
    var entries = raw.iterator();
    while (entries.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value != .object) continue;
        try records.put(arena, entry.key_ptr.*, try wikidataRecordLeaky(arena, value.object));
    }
    return records;
}

fn wikidataRecordLeaky(arena: Allocator, object: std.json.ObjectMap) !WikidataRecord {
    var images: std.ArrayList([]const u8) = .empty;
    if (object.get("images")) |list| {
        if (list == .array) {
            for (list.array.items) |item| {
                if (item == .string) try images.append(arena, item.string);
            }
        }
    }
    var identifiers: std.ArrayList(Identifier) = .empty;
    if (object.get("identifiants")) |map| {
        if (map == .object) {
            var pairs = map.object.iterator();
            while (pairs.next()) |pair| {
                if (pair.value_ptr.* == .string) try identifiers.append(arena, .{
                    .key = pair.key_ptr.*,
                    .value = pair.value_ptr.string,
                });
            }
        }
    }
    return .{
        .qid = stringField(object, "qid") orelse "",
        .images = images.items,
        .identifiers = identifiers.items,
        .french_label = stringField(object, "libelle_fr"),
        .frwiki = stringField(object, "frwiki"),
        .enwiki = stringField(object, "enwiki"),
    };
}

/// One SPARQL query per batch of canonical names, aggregating rows by name.
///
/// The cached shape keeps the French field names the Python wrote, because the
/// 564 entries on disk use them and rewriting the cache would mean re-querying
/// Wikidata for nothing.
fn wikidataBatchLeaky(
    client: *http.Client,
    arena: Allocator,
    batch: []const []const u8,
) !std.StringArrayHashMapUnmanaged(std.json.Value) {
    var values: std.ArrayList(u8) = .empty;
    for (batch) |name| {
        // A name carrying a double quote would break out of the SPARQL literal.
        if (std.mem.indexOfScalar(u8, name, '"') != null) continue;
        try values.print(arena, "\"{s}\" ", .{name});
    }
    const query = try std.mem.replaceOwned(
        u8,
        arena,
        taxon_query,
        "%s",
        std.mem.trim(u8, values.items, " "),
    );

    const answer = try client.fetchLeaky(arena, wikidata_sparql, &.{
        .{ .name = "query", .value = query },
        .{ .name = "format", .value = "json" },
    }, .post_form) orelse return .empty;

    var records: std.StringArrayHashMapUnmanaged(std.json.Value) = .empty;
    const bindings = pathArray(answer, &.{ "results", "bindings" }) orelse return records;
    for (bindings) |row| {
        if (row != .object) continue;
        const name = sparqlValue(row.object, "nom") orelse continue;
        const item = lastSegment(sparqlValue(row.object, "item") orelse "");

        const slot = try records.getOrPut(arena, name);
        if (!slot.found_existing) {
            var fresh: std.json.ObjectMap = .empty;
            try fresh.put(arena, "qid", .{ .string = item });
            try fresh.put(arena, "images", .{ .array = .init(arena) });
            try fresh.put(arena, "identifiants", .{ .object = .empty });
            slot.value_ptr.* = .{ .object = fresh };
        }
        var record = slot.value_ptr.object;
        // Homonyms: stay with the first item seen.
        if (!std.mem.eql(u8, record.get("qid").?.string, item)) continue;

        if (sparqlValue(row.object, "image")) |image| {
            var list = record.get("images").?.array;
            var known = false;
            for (list.items) |existing| known = known or std.mem.eql(u8, existing.string, image);
            if (!known) {
                try list.append(.{ .string = image });
                try record.put(arena, "images", .{ .array = list });
            }
        }
        for ([_][2][]const u8{
            .{ "libelle", "libelle_fr" },
            .{ "frwiki", "frwiki" },
            .{ "enwiki", "enwiki" },
        }) |pair| {
            if (sparqlValue(row.object, pair[0])) |found| {
                try record.put(arena, pair[1], .{ .string = found });
            }
        }
        var identifiers = record.get("identifiants").?.object;
        for ([_][2][]const u8{
            .{ "gbif", "gbif" },
            .{ "inat", "inaturalist" },
            .{ "tela", "tela_botanica" },
            .{ "commons", "commons" },
        }) |pair| {
            if (sparqlValue(row.object, pair[0])) |found| {
                try identifiers.put(arena, pair[1], .{ .string = found });
            }
        }
        try record.put(arena, "identifiants", .{ .object = identifiers });
        slot.value_ptr.* = .{ .object = record };
    }
    return records;
}

fn sparqlValue(row: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const cell = row.get(field) orelse return null;
    if (cell != .object) return null;
    return stringField(cell.object, "value");
}

// ------------------------------------------------------------------ Wikipedia

pub const Summary = struct {
    language: []const u8,
    page_title: []const u8,
    text: []const u8,
    url: []const u8,
    /// The file illustrating the article. Plumbing for the image pass; it never
    /// reaches the output.
    image_file: ?[]const u8 = null,
};

pub fn wikipediaSummariesLeaky(
    client: *http.Client,
    arena: Allocator,
    titles: []const []const u8,
    language: []const u8,
) !std.StringArrayHashMapUnmanaged(Summary) {
    const source = try std.fmt.allocPrint(arena, "wikipedia-{s}", .{language});
    const raw = try batchedCacheLeaky(
        client,
        arena,
        source,
        titles,
        extracts_per_request,
        .{ .wikipedia = language },
    );

    var summaries: std.StringArrayHashMapUnmanaged(Summary) = .empty;
    var entries = raw.iterator();
    while (entries.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value != .object) continue;
        try summaries.put(arena, entry.key_ptr.*, .{
            .language = stringField(value.object, "langue") orelse language,
            .page_title = stringField(value.object, "titre_page") orelse "",
            .text = stringField(value.object, "texte") orelse "",
            .url = stringField(value.object, "url") orelse "",
            .image_file = stringField(value.object, "fichier_image"),
        });
    }
    return summaries;
}

fn wikipediaBatchLeaky(
    client: *http.Client,
    arena: Allocator,
    batch: []const []const u8,
    language: []const u8,
) !std.StringArrayHashMapUnmanaged(std.json.Value) {
    const url = try std.fmt.allocPrint(arena, "https://{s}.wikipedia.org/w/api.php", .{language});
    const answer = try client.fetchLeaky(arena, url, &.{
        .{ .name = "action", .value = "query" },
        .{ .name = "format", .value = "json" },
        .{ .name = "formatversion", .value = "2" },
        .{ .name = "redirects", .value = "1" },
        .{ .name = "prop", .value = "extracts|pageimages" },
        .{ .name = "exintro", .value = "1" },
        .{ .name = "explaintext", .value = "1" },
        .{ .name = "exlimit", .value = std.fmt.comptimePrint("{d}", .{extracts_per_request}) },
        .{ .name = "piprop", .value = "thumbnail|name" },
        .{ .name = "pithumbsize", .value = "1200" },
        .{ .name = "titles", .value = try std.mem.join(arena, "|", batch) },
    }, .get) orelse return .empty;

    const pages = try requestedPagesLeaky(arena, answer, batch);
    var results: std.StringArrayHashMapUnmanaged(std.json.Value) = .empty;
    var entries = pages.iterator();
    while (entries.next()) |entry| {
        const page = entry.value_ptr.*;
        const extract = stringField(page, "extract") orelse continue;
        if (extract.len == 0) continue;
        const title = stringField(page, "title") orelse continue;

        var record: std.json.ObjectMap = .empty;
        try record.put(arena, "langue", .{ .string = language });
        try record.put(arena, "titre_page", .{ .string = title });
        try record.put(arena, "texte", .{ .string = extract });
        try record.put(arena, "url", .{ .string = try articleUrlLeaky(arena, language, title) });
        if (stringField(page, "pageimage")) |file| {
            try record.put(arena, "fichier_image", .{ .string = file });
        }
        try results.put(arena, entry.key_ptr.*, .{ .object = record });
    }
    return results;
}

fn articleUrlLeaky(arena: Allocator, language: []const u8, title: []const u8) ![]const u8 {
    const underscored = try arena.dupe(u8, title);
    for (underscored) |*byte| {
        if (byte.* == ' ') byte.* = '_';
    }
    return std.fmt.allocPrint(arena, "https://{s}.wikipedia.org/wiki/{s}", .{
        language,
        underscored,
    });
}

/// Maps each requested title back to its page: the API normalises the title,
/// then follows redirects, and both hops have to be replayed.
fn requestedPagesLeaky(
    arena: Allocator,
    answer: std.json.Value,
    batch: []const []const u8,
) !std.StringArrayHashMapUnmanaged(std.json.ObjectMap) {
    var hops: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for ([_][]const u8{ "normalized", "redirects" }) |stage| {
        const list = pathArray(answer, &.{ "query", stage }) orelse continue;
        for (list) |hop| {
            if (hop != .object) continue;
            const from = stringField(hop.object, "from") orelse continue;
            const to = stringField(hop.object, "to") orelse continue;
            try hops.put(arena, from, to);
        }
    }

    var pages: std.StringArrayHashMapUnmanaged(std.json.ObjectMap) = .empty;
    if (pathArray(answer, &.{ "query", "pages" })) |list| {
        for (list) |page| {
            if (page != .object) continue;
            if (page.object.get("missing") != null) continue;
            const title = stringField(page.object, "title") orelse continue;
            try pages.put(arena, title, page.object);
        }
    }

    var requested: std.StringArrayHashMapUnmanaged(std.json.ObjectMap) = .empty;
    for (batch) |title| {
        var final = title;
        var steps: usize = 0;
        // A redirect loop would otherwise spin here forever.
        while (hops.get(final)) |next| : (steps += 1) {
            if (steps > hops.count()) break;
            final = next;
        }
        if (pages.get(final)) |page| try requested.put(arena, title, page);
    }
    return requested;
}

// -------------------------------------------------------------------- Commons

pub fn commonsFilesLeaky(
    client: *http.Client,
    arena: Allocator,
    files: []const []const u8,
) !std.StringArrayHashMapUnmanaged(model.Image) {
    const raw = try batchedCacheLeaky(
        client,
        arena,
        "commons",
        files,
        titles_per_request,
        .commons,
    );

    var images: std.StringArrayHashMapUnmanaged(model.Image) = .empty;
    var entries = raw.iterator();
    while (entries.next()) |entry| {
        const value = entry.value_ptr.*;
        if (value != .object) continue;
        const record = value.object;
        const licence = stringField(record, "licence") orelse continue;
        try images.put(arena, entry.key_ptr.*, .{
            .source = "commons",
            .file = stringField(record, "fichier"),
            .url = stringField(record, "url") orelse "",
            .source_url = stringField(record, "url_source") orelse "",
            .width = @intCast(integerField(record, "largeur") orelse 0),
            .height = @intCast(integerField(record, "hauteur") orelse 0),
            .author = stringField(record, "auteur") orelse "",
            .credit = stringField(record, "credit") orelse "",
            .licence = licence,
            .licence_url = stringField(record, "url_licence") orelse "",
            .scope = "taxon_exact",
            .primary = false,
        });
    }
    return images;
}

fn commonsBatchLeaky(
    client: *http.Client,
    arena: Allocator,
    batch: []const []const u8,
) !std.StringArrayHashMapUnmanaged(std.json.Value) {
    const answer = try client.fetchLeaky(arena, commons_api, &.{
        .{ .name = "action", .value = "query" },
        .{ .name = "format", .value = "json" },
        .{ .name = "formatversion", .value = "2" },
        .{ .name = "prop", .value = "imageinfo" },
        .{ .name = "iiprop", .value = "extmetadata|url|size" },
        .{ .name = "iiurlwidth", .value = std.fmt.comptimePrint("{d}", .{thumbnail_width}) },
        .{ .name = "titles", .value = try std.mem.join(arena, "|", batch) },
    }, .get) orelse return .empty;

    const pages = try requestedPagesLeaky(arena, answer, batch);
    var results: std.StringArrayHashMapUnmanaged(std.json.Value) = .empty;
    var entries = pages.iterator();
    while (entries.next()) |entry| {
        const page = entry.value_ptr.*;
        const infos = page.get("imageinfo") orelse continue;
        if (infos != .array or infos.array.items.len == 0) continue;
        const info = infos.array.items[0];
        if (info != .object) continue;
        const meta = if (info.object.get("extmetadata")) |found|
            (if (found == .object) found.object else null)
        else
            null;

        const licence = licenceCode(&.{
            try metaFieldLeaky(arena, meta, "LicenseShortName"),
            try metaFieldLeaky(arena, meta, "License"),
            try metaFieldLeaky(arena, meta, "UsageTerms"),
        }) orelse continue;

        var record: std.json.ObjectMap = .empty;
        try record.put(arena, "source", .{ .string = "commons" });
        try record.put(arena, "fichier", .{ .string = stringField(page, "title") orelse "" });
        try record.put(arena, "url", .{ .string = withoutTracking(
            stringField(info.object, "thumburl") orelse stringField(info.object, "url") orelse "",
        ) });
        try record.put(arena, "url_source", .{ .string = stringField(info.object, "descriptionurl") orelse "" });
        try record.put(arena, "largeur", .{ .integer = integerField(info.object, "thumbwidth") orelse
            integerField(info.object, "width") orelse 0 });
        try record.put(arena, "hauteur", .{ .integer = integerField(info.object, "thumbheight") orelse
            integerField(info.object, "height") orelse 0 });
        try record.put(arena, "auteur", .{ .string = try metaFieldLeaky(arena, meta, "Artist") });
        try record.put(arena, "credit", .{ .string = try metaFieldLeaky(arena, meta, "Credit") });
        try record.put(arena, "licence", .{ .string = licence });
        const explicit = try metaFieldLeaky(arena, meta, "LicenseUrl");
        try record.put(arena, "url_licence", .{ .string = if (explicit.len > 0)
            explicit
        else
            licenceUrl(licence) });

        try results.put(arena, entry.key_ptr.*, .{ .object = record });
    }
    return results;
}

fn metaFieldLeaky(arena: Allocator, meta: ?std.json.ObjectMap, field: []const u8) ![]const u8 {
    const map = meta orelse return "";
    const entry = map.get(field) orelse return "";
    if (entry != .object) return "";
    return plainTextLeaky(arena, stringField(entry.object, "value") orelse "");
}

// ---------------------------------------------------------------- iNaturalist

/// Research-grade observation photos, filtered on the accepted licences.
pub fn inatPhotosLeaky(
    client: *http.Client,
    arena: Allocator,
    canonical_name: []const u8,
    licences: []const []const u8,
    limit: usize,
) ![]const model.Image {
    var codes: std.ArrayList(u8) = .empty;
    for (licences, 0..) |code, at| {
        if (at > 0) try codes.append(arena, ',');
        try codes.appendSlice(arena, if (std.mem.eql(u8, code, "domaine-public")) "cc0" else code);
    }

    // The licence list is part of the cache key: asking for a different set is
    // a different question, and must not read back the previous answer.
    const key = try std.fmt.allocPrint(arena, "{s}-{s}", .{ canonical_name, codes.items });
    const answer = try client.cachedLeaky(arena, "inaturalist", key, inaturalist, &.{
        .{ .name = "taxon_name", .value = canonical_name },
        .{ .name = "photo_license", .value = codes.items },
        .{ .name = "quality_grade", .value = "research" },
        .{ .name = "order_by", .value = "votes" },
        .{ .name = "per_page", .value = "5" },
        .{ .name = "photos", .value = "true" },
    }, .get) orelse return &.{};

    var photos: std.ArrayList(model.Image) = .empty;
    const observations = pathArray(answer, &.{"results"}) orelse return &.{};
    for (observations) |observation| {
        if (observation != .object) continue;
        const list = observation.object.get("photos") orelse continue;
        if (list != .array) continue;
        for (list.array.items) |photo| {
            if (photo != .object) continue;
            const licence = licenceCode(&.{stringField(photo.object, "license_code") orelse ""}) orelse continue;
            if (!isOneOf(licence, licences)) continue;
            const url = stringField(photo.object, "url") orelse continue;

            const dimensions = if (photo.object.get("original_dimensions")) |found|
                (if (found == .object) found.object else null)
            else
                null;
            const size = std.mem.replacementSize(u8, url, "square", "large");
            const large = try arena.alloc(u8, size);
            _ = std.mem.replace(u8, url, "square", "large", large);

            try photos.append(arena, .{
                .source = "inaturalist",
                .url = large,
                .source_url = try std.fmt.allocPrint(
                    arena,
                    "https://www.inaturalist.org/photos/{d}",
                    .{integerField(photo.object, "id") orelse 0},
                ),
                .width = @intCast(if (dimensions) |d| integerField(d, "width") orelse 0 else 0),
                .height = @intCast(if (dimensions) |d| integerField(d, "height") orelse 0 else 0),
                .author = try plainTextLeaky(arena, stringField(photo.object, "attribution") orelse ""),
                .credit = try plainTextLeaky(arena, stringField(observation.object, "species_guess") orelse ""),
                .licence = licence,
                .licence_url = licenceUrl(licence),
                .scope = "taxon_exact",
                .primary = false,
            });
            if (photos.items.len >= limit) return photos.items;
        }
    }
    return photos.items;
}

// ------------------------------------------------------------------- licences

/// Reduces a licence mention ("CC BY-SA 4.0", "cc-by-nc") to a registry code.
///
/// An ND match returns null: no derivatives means no thumbnail, so the image
/// cannot be used here at all.
pub fn licenceCode(mentions: []const []const u8) ?[]const u8 {
    var buffer: [256]u8 = undefined;
    for (mentions) |mention| {
        if (mention.len == 0) continue;
        const length = @min(buffer.len, mention.len);
        for (mention[0..length], buffer[0..length]) |byte, *slot| {
            slot.* = switch (byte) {
                '_', ' ' => '-',
                else => std.ascii.toLower(byte),
            };
        }
        const lower = buffer[0..length];

        if (std.mem.indexOf(u8, lower, "cc0") != null or
            std.mem.indexOf(u8, lower, "zero") != null) return "cc0";
        if (std.mem.indexOf(u8, lower, "public-domain") != null or
            std.mem.startsWith(u8, lower, "pd-") or
            std.mem.indexOf(u8, lower, "publicdomain") != null) return "domaine-public";
        if (creativeCommons(lower)) |code| return code;
    }
    return null;
}

/// Matches `cc-?by(-nc)?(-sa)?(-nd)?` and rebuilds the code from the parts.
fn creativeCommons(lower: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, lower, at, "cc")) |start| : (at = start + 1) {
        var cursor = start + 2;
        if (cursor < lower.len and lower[cursor] == '-') cursor += 1;
        if (!std.mem.startsWith(u8, lower[cursor..], "by")) continue;
        cursor += 2;

        const non_commercial = std.mem.startsWith(u8, lower[cursor..], "-nc");
        if (non_commercial) cursor += 3;
        const share_alike = std.mem.startsWith(u8, lower[cursor..], "-sa");
        if (share_alike) cursor += 3;
        if (std.mem.startsWith(u8, lower[cursor..], "-nd")) return null;

        if (non_commercial and share_alike) return "cc-by-nc-sa";
        if (non_commercial) return "cc-by-nc";
        if (share_alike) return "cc-by-sa";
        return "cc-by";
    }
    return null;
}

pub fn licenceUrl(code: []const u8) []const u8 {
    const urls = [_][2][]const u8{
        .{ "cc0", "https://creativecommons.org/publicdomain/zero/1.0/" },
        .{ "domaine-public", "https://creativecommons.org/publicdomain/mark/1.0/" },
        .{ "cc-by", "https://creativecommons.org/licenses/by/4.0/" },
        .{ "cc-by-sa", "https://creativecommons.org/licenses/by-sa/4.0/" },
        .{ "cc-by-nc", "https://creativecommons.org/licenses/by-nc/4.0/" },
        .{ "cc-by-nc-sa", "https://creativecommons.org/licenses/by-nc-sa/4.0/" },
    };
    for (urls) |entry| {
        if (std.mem.eql(u8, entry[0], code)) return entry[1];
    }
    return "";
}

/// Strips the HTML markup out of the Commons Artist and Credit fields, decodes
/// the entities, and squeezes the whitespace.
pub fn plainTextLeaky(arena: Allocator, fragment: []const u8) ![]const u8 {
    if (fragment.len == 0) return "";

    var without_tags: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    while (at < fragment.len) {
        if (fragment[at] == '<') {
            const close = std.mem.indexOfScalarPos(u8, fragment, at, '>') orelse break;
            try without_tags.append(arena, ' ');
            at = close + 1;
            continue;
        }
        try without_tags.append(arena, fragment[at]);
        at += 1;
    }

    const decoded = try xml.decodeAlloc(arena, without_tags.items);
    var squeezed: std.ArrayList(u8) = .empty;
    var in_space = false;
    for (decoded) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            if (!in_space) try squeezed.append(arena, ' ');
            in_space = true;
        } else {
            try squeezed.append(arena, byte);
            in_space = false;
        }
    }
    return std.mem.trim(u8, squeezed.items, " ");
}

// -------------------------------------------------------------------- helpers

fn withoutTracking(url: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, url, '?') orelse return url;
    return url[0..query];
}

fn lastSegment(url: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, url, '/') orelse return url;
    return url[slash + 1 ..];
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return if (value == .string) value.string else null;
}

fn integerField(object: std.json.ObjectMap, field: []const u8) ?i64 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .integer => |number| number,
        .float => |number| @intFromFloat(number),
        else => null,
    };
}

fn pathArray(value: std.json.Value, path: []const []const u8) ?[]const std.json.Value {
    var current = value;
    for (path) |step| {
        if (current != .object) return null;
        current = current.object.get(step) orelse return null;
    }
    return if (current == .array) current.array.items else null;
}

fn isOneOf(needle: []const u8, haystack: []const []const u8) bool {
    for (haystack) |candidate| {
        if (std.mem.eql(u8, candidate, needle)) return true;
    }
    return false;
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

const testing_gpa = std.testing.allocator;

test "licence mentions reduce to registry codes" {
    try std.testing.expectEqualStrings("cc-by-sa", licenceCode(&.{"CC BY-SA 4.0"}).?);
    try std.testing.expectEqualStrings("cc-by", licenceCode(&.{"cc by 2.0"}).?);
    try std.testing.expectEqualStrings("cc-by-nc", licenceCode(&.{"CC-BY-NC-3.0"}).?);
    try std.testing.expectEqualStrings("cc-by-nc-sa", licenceCode(&.{"cc_by_nc_sa_4.0"}).?);
    try std.testing.expectEqualStrings("cc0", licenceCode(&.{"CC0 1.0"}).?);
    try std.testing.expectEqualStrings("domaine-public", licenceCode(&.{"Public domain"}).?);
    try std.testing.expectEqualStrings("domaine-public", licenceCode(&.{"PD-old-70"}).?);
}

test "a no-derivatives licence is refused, because a thumbnail is a derivative" {
    try std.testing.expect(licenceCode(&.{"CC BY-ND 4.0"}) == null);
    try std.testing.expect(licenceCode(&.{"CC BY-NC-ND 4.0"}) == null);
    try std.testing.expect(licenceCode(&.{"All rights reserved"}) == null);
    try std.testing.expect(licenceCode(&.{""}) == null);
}

test "every code the licence reader emits is one the policy accepts" {
    for ([_][]const u8{ "CC BY-SA", "CC BY", "CC BY-NC", "CC BY-NC-SA", "CC0", "public domain" }) |mention| {
        const code = licenceCode(&.{mention}).?;
        try std.testing.expect(licence_policy.isAccepted(code));
        try std.testing.expect(licenceUrl(code).len > 0);
    }
}

test "the first mention that resolves wins" {
    try std.testing.expectEqualStrings(
        "cc-by-sa",
        licenceCode(&.{ "", "unhelpful", "CC BY-SA 4.0", "CC0" }).?,
    );
}

test "markup and entities are stripped out of credit fields" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "Jane Doe",
        try plainTextLeaky(arena, "<a href=\"/wiki/User:Jane\">Jane Doe</a>"),
    );
    try std.testing.expectEqualStrings(
        "A & B",
        try plainTextLeaky(arena, "  A &amp;   B  "),
    );
    try std.testing.expectEqualStrings("", try plainTextLeaky(arena, ""));
}

test "tracking parameters are dropped from image URLs" {
    try std.testing.expectEqualStrings(
        "https://upload.wikimedia.org/a.jpg",
        withoutTracking("https://upload.wikimedia.org/a.jpg?20240101"),
    );
}
