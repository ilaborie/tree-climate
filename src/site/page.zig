//! The site's five page templates and the components they share.
//!
//! Visible text is French because the readers are; everything around it is
//! English like the rest of the code.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const model = @import("../model.zig");
const catalogue = @import("catalogue.zig");
const credits = @import("../credits.zig");
const html_mod = @import("html.zig");
const Builder = html_mod.Builder;
const Entry = catalogue.Entry;

pub const site_title = "Essences adaptées au changement climatique";

/// Widths of the two WebP derivatives: thumbnails and sheet illustrations.
pub const thumb_width = 320;
pub const full_width = 500;
/// Card thumbnails are cropped to this height by the stylesheet; stating it
/// keeps the layout from jumping while images load.
const thumb_height = 240;

const related_shown = 12;

/// Filterable criteria on the list page. The values come from the data legend,
/// never from a list written out again here.
const facet_labels = [_]struct { key: []const u8, label: []const u8 }{
    .{ .key = "acidity", .label = "Sol" },
    .{ .key = "moisture", .label = "Humidité" },
    .{ .key = "exposure", .label = "Exposition" },
    .{ .key = "traits", .label = "Particularités" },
};

const languages = [_]struct { code: []const u8, name: []const u8 }{
    .{ .code = "en", .name = "l'anglais" },
    .{ .code = "es", .name = "l'espagnol" },
    .{ .code = "de", .name = "l'allemand" },
};

/// The hashed asset filenames Vite produced for this build.
pub const Assets = struct {
    script: []const u8,
    stylesheet: []const u8,
};

pub const Context = struct {
    arena: Allocator,
    dataset: *const model.EnrichedDataset,
    entries: []const Entry,
    assets: Assets,
    /// Public origin, for canonical links. Empty when unknown.
    site_url: []const u8,

    fn licence(self: Context, code: []const u8) model.Licence {
        return self.dataset.licences.map.get(code) orelse .{
            .name = code,
            .url = "",
            .attribution = true,
            .share_alike = false,
            .commercial = false,
        };
    }
};

// ------------------------------------------------------------------ shell

const Shell = struct {
    title: []const u8,
    summary: []const u8,
    /// Relative prefix back to the site root: "", "../" or "../../".
    root: []const u8,
    tab: ?[]const u8 = null,
    /// Path below the site root, for the canonical link.
    path: []const u8 = "",
};

fn shellOpen(html: Builder, context: Context, shell: Shell) !void {
    try html.raw("<!doctype html>");
    try html.open("html", .{ .lang = "fr" });
    try html.open("head", .{});
    try html.empty("meta", .{ .charset = "utf-8" });
    try html.empty("meta", .{
        .name = "viewport",
        .content = "width=device-width, initial-scale=1",
    });
    try html.element("title", .{}, shell.title);
    try html.empty("meta", .{ .name = "description", .content = shell.summary });
    try html.empty("meta", .{ .property = "og:title", .content = shell.title });
    try html.empty("meta", .{ .property = "og:description", .content = shell.summary });
    try html.empty("meta", .{ .property = "og:type", .content = "website" });
    if (context.site_url.len > 0) {
        const canonical = try std.mem.concat(context.arena, u8, &.{
            context.site_url, "/", shell.path,
        });
        try html.empty("link", .{ .rel = "canonical", .href = canonical });
        try html.empty("meta", .{ .property = "og:url", .content = canonical });
    }
    try html.empty("link", .{
        .rel = "stylesheet",
        .href = try std.mem.concat(context.arena, u8, &.{
            shell.root, "assets/", context.assets.stylesheet,
        }),
    });
    try html.close("head");

    try html.open("body", .{});
    try html.open("a", .{ .href = "#content", .class_ = "skip-link" });
    try html.text("Aller au contenu");
    try html.close("a");

    try html.open("header", .{ .class_ = "site-header" });
    try html.open("div", .{ .class_ = "container" });
    try html.open("p", .{ .class_ = "header__title" });
    try html.link(if (shell.root.len > 0) shell.root else "./", site_title);
    try html.close("p");
    try html.open("nav", .{ .aria_label = "Navigation principale" });
    for ([_]struct { target: []const u8, label: []const u8 }{
        .{ .target = "essences/", .label = "Essences" },
        .{ .target = "credits/", .label = "Crédits" },
    }) |tab| {
        const current = shell.tab != null and std.mem.eql(u8, shell.tab.?, tab.target);
        try html.open("a", .{
            .href = try std.mem.concat(context.arena, u8, &.{ shell.root, tab.target }),
            .aria_current = if (current) @as(?[]const u8, "page") else null,
        });
        try html.text(tab.label);
        try html.close("a");
    }
    try html.close("nav");
    try html.close("div");
    try html.close("header");

    try html.open("main", .{ .id = "content" });
    try html.open("div", .{ .class_ = "container" });
}

fn shellClose(html: Builder, context: Context, shell: Shell) !void {
    try html.close("div");
    try html.close("main");

    const source = context.dataset.source;
    try html.open("footer", .{ .class_ = "site-footer" });
    try html.open("div", .{ .class_ = "container" });

    try html.open("p", .{});
    try html.text("Données extraites de ");
    try html.open("a", .{ .href = source.url });
    try html.print("« ", .{});
    try html.text(source.document);
    try html.print(" »", .{});
    try html.close("a");
    try html.text(" du ");
    try html.text(source.publisher);
    try html.print(" (", .{});
    try html.text(source.date);
    try html.print(").", .{});
    try html.close("p");

    try html.open("p", .{});
    try html.text("Descriptions issues de Wikipédia, sous licence ");
    try html.open("a", .{
        .href = "https://creativecommons.org/licenses/by-sa/4.0/",
        .rel = "license",
    });
    try html.text("CC BY-SA 4.0");
    try html.close("a");
    try html.text(" : ce site est diffusé sous la même licence.");
    try html.close("p");

    try html.open("p", .{});
    try html.text("Images sous les licences indiquées sous chacune d'elles. Certaines sont " ++
        "en CC BY-NC : ce site ne peut pas être exploité commercialement. ");
    try html.link(
        try std.mem.concat(context.arena, u8, &.{ shell.root, "credits/" }),
        "Sources et licences détaillées",
    );
    try html.text(".");
    try html.close("p");

    try html.close("div");
    try html.close("footer");

    // One bundle on every page rather than two entry points: it early-returns
    // where there is no search form, and a single cached module beats a second
    // build target.
    try html.empty("script", .{
        .type = "module",
        .src = try std.mem.concat(context.arena, u8, &.{
            shell.root, "assets/", context.assets.script,
        }),
    });
    try html.close("script");
    try html.close("body");
    try html.close("html");
    try html.raw("\n");
}

// ------------------------------------------------------------------ components

/// Author, linked licence and source page: the three mentions every image must
/// carry, next to that image and never as a blanket statement.
fn imageCredit(html: Builder, context: Context, image: model.Image) !void {
    const licence = context.licence(image.licence);
    if (image.author.len > 0) {
        try html.text(image.author);
        try html.text(" — ");
    }
    try html.open("a", .{
        .href = if (image.licence_url.len > 0) image.licence_url else licence.url,
        .rel = "license",
    });
    try html.text(licence.name);
    try html.close("a");
    if (image.source_url.len > 0) {
        try html.text(" · ");
        try html.link(image.source_url, "source");
    }
}

const Size = struct { width: u32, height: u32 };

/// What `-resize NxN>` actually produced: it only ever shrinks.
///
/// Python rounded half to even here; this rounds half away from zero. The
/// difference is at most one pixel on a layout hint.
fn derivedSize(image: model.Image, target: u32) Size {
    const width = if (image.width > 0) image.width else target;
    const height = image.height;
    if (height == 0 or width <= target) return .{ .width = width, .height = height };
    const scaled = @round(@as(f64, @floatFromInt(height)) *
        @as(f64, @floatFromInt(target)) / @as(f64, @floatFromInt(width)));
    return .{ .width = target, .height = @intFromFloat(scaled) };
}

fn illustration(html: Builder, context: Context, entry: Entry, root: []const u8) !void {
    try html.open("figure", .{ .class_ = "sheet__illustration" });
    const image = entry.primary_image orelse {
        try html.element(
            "div",
            .{ .class_ = "card__thumb card__empty" },
            "Aucune image libre disponible pour cette essence",
        );
        try html.close("figure");
        return;
    };

    const size = derivedSize(image.*, full_width);
    const caption = if (entry.species.french_names.len > 0)
        try std.mem.concat(context.arena, u8, &.{
            entry.species.latin_name, " (", entry.species.french_names[0], ")",
        })
    else
        entry.species.latin_name;

    // Above the fold on every sheet, so eager rather than lazy: deferring it
    // would delay the one thing the page is about.
    try html.empty("img", .{
        .src = try std.fmt.allocPrint(context.arena, "{s}img/{s}-{d}.webp", .{
            root, entry.slug, full_width,
        }),
        .alt = caption,
        .width = if (size.width > 0) @as(?u32, size.width) else null,
        .height = if (size.height > 0) @as(?u32, size.height) else null,
        .loading = "eager",
        .fetchpriority = "high",
    });
    try html.open("figcaption", .{ .class_ = "credit" });
    try imageCredit(html, context, image.*);
    try html.close("figcaption");
    try html.close("figure");
}

fn characteristicRow(
    html: Builder,
    label: []const u8,
    values: []const []const u8,
    code: ?[]const u8,
) !void {
    if (values.len == 0) return;
    try html.element("dt", .{ .class_ = "label" }, label);
    try html.open("dd", .{});
    for (values) |value| try html.element("span", .{ .class_ = "chip" }, value);
    if (code) |present| try html.element("span", .{ .class_ = "code" }, present);
    try html.close("dd");
}

fn characteristics(html: Builder, context: Context, entry: Entry) !void {
    const species = entry.species;
    try html.open("dl", .{ .class_ = "characteristics" });

    if (species.height_m) |metres| {
        const shown = try std.fmt.allocPrint(context.arena, "{d} m", .{metres});
        try characteristicRow(html, "Hauteur adulte", &.{shown}, null);
    }
    try characteristicRow(html, "Sol", species.acidity, species.codes.acidity);
    try characteristicRow(html, "Humidité", species.moisture, species.codes.moisture);
    try characteristicRow(html, "Exposition", species.exposure, species.codes.exposure);
    try characteristicRow(html, "Particularités", species.traits, species.codes.traits);
    if (entry.family.len > 0) try characteristicRow(html, "Famille", &.{entry.family}, null);
    try characteristicRow(html, "Disponibilité", &.{
        if (std.mem.eql(u8, species.availability, "disponible"))
            "disponible en pépinière"
        else
            "peu disponible",
    }, null);

    try html.close("dl");
}

/// Without this block, a description of the genus would read as one of the
/// cultivar.
fn warnings(html: Builder, entry: Entry) !void {
    const messages = entry.species.enrichment.warnings;
    if (messages.len == 0) return;
    try html.open("div", .{ .class_ = "alert", .role = "note" });
    for (messages) |message| try html.element("p", .{}, message);
    try html.close("div");
}

fn paragraphs(html: Builder, body: []const u8) !void {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        const paragraph = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (paragraph.len == 0) continue;
        try html.element("p", .{}, paragraph);
    }
}

fn description(html: Builder, context: Context, entry: Entry) !void {
    const descriptions = entry.species.enrichment.descriptions;
    if (descriptions.len == 0) {
        try html.element(
            "p",
            .{ .class_ = "prose" },
            "Aucune description libre n'a été trouvée pour cette essence.",
        );
        return;
    }
    const first = descriptions[0];
    const licence = context.licence(first.licence);

    try html.open("div", .{ .class_ = "prose" });
    try paragraphs(html, first.text);

    try html.open("p", .{ .class_ = "credit" });
    if (first.translated_from) |origin| {
        // A translation is a derivative work: it stays under the licence of the
        // source article, and that article is the one to credit and link.
        var language: []const u8 = "sa langue d'origine";
        for (languages) |known| {
            if (std.mem.eql(u8, known.code, origin.language)) language = known.name;
        }
        try html.open("a", .{ .href = origin.url });
        try html.text("Wikipédia — ");
        try html.text(origin.page_title);
        try html.text(", traduit de ");
        try html.text(language);
        try html.close("a");
    } else {
        try html.open("a", .{ .href = first.url });
        try html.text("Wikipédia (");
        try html.text(first.language);
        try html.text(") — ");
        try html.text(first.page_title);
        try html.close("a");
    }
    try html.text(" — ");
    try html.open("a", .{ .href = licence.url, .rel = "license" });
    try html.text(licence.name);
    try html.close("a");
    try html.close("p");

    try html.close("div");
}

/// Secondary images are not downloaded: the sheet gives their source, not a
/// thumbnail hotlinked from someone else's server.
fn otherImages(html: Builder, context: Context, entry: Entry) !void {
    const shown_url = if (entry.primary_image) |image| image.source_url else "";
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(context.arena);
    if (shown_url.len > 0) try seen.append(context.arena, shown_url);

    var body: Writer.Allocating = .init(context.arena);
    const inner: Builder = .{ .out = &body.writer };
    for (entry.species.enrichment.images) |image| {
        const key = if (image.source_url.len > 0) image.source_url else image.url;
        var known = false;
        for (seen.items) |already| known = known or std.mem.eql(u8, already, key);
        if (known) continue;
        try seen.append(context.arena, key);

        try inner.open("li", .{});
        try imageCredit(inner, context, image);
        try inner.close("li");
    }
    if (body.written().len == 0) return;

    try html.element("h2", .{}, "Autres images libres");
    try html.open("ul", .{ .class_ = "gallery" });
    try html.raw(body.written());
    try html.close("ul");
}

fn externalLinks(html: Builder, entry: Entry) !void {
    const links = entry.species.enrichment.links;
    if (links.len == 0) return;
    try html.element("h2", .{}, "En savoir plus");
    try html.open("ul", .{ .class_ = "links" });
    for (links) |reference| {
        try html.open("li", .{});
        try html.link(reference.url, reference.label);
        try html.close("li");
    }
    try html.close("ul");
}

/// Botanical neighbourhood, same genus first: that is the comparison a reader
/// can actually use.
fn sameFamily(html: Builder, context: Context, entry: Entry, relatives: []const usize) !void {
    if (relatives.len == 0) return;
    const genus = if (entry.species.enrichment.taxon) |taxon| taxon.genus else "";

    const ordered = try context.arena.dupe(usize, relatives);
    const Sorter = struct {
        entries: []const Entry,
        genus: []const u8,
        fn before(self: @This(), a: usize, b: usize) bool {
            const a_same = self.sameGenus(a);
            const b_same = self.sameGenus(b);
            if (a_same != b_same) return a_same;
            return std.mem.lessThan(
                u8,
                self.entries[a].species.latin_name,
                self.entries[b].species.latin_name,
            );
        }
        fn sameGenus(self: @This(), at: usize) bool {
            const taxon = self.entries[at].species.enrichment.taxon orelse return false;
            return std.mem.eql(u8, taxon.genus, self.genus);
        }
    };
    std.mem.sort(usize, ordered, Sorter{ .entries = context.entries, .genus = genus }, Sorter.before);

    const total = relatives.len + 1;
    try html.open("h2", .{});
    try html.text("Même famille — ");
    try html.text(entry.family_fr);
    try html.print(" ({d} essences)", .{total});
    try html.close("h2");

    try html.open("ul", .{ .class_ = "links" });
    for (ordered[0..@min(ordered.len, related_shown)]) |at| {
        const relative = context.entries[at];
        try html.open("li", .{});
        try html.open("a", .{
            .href = try std.mem.concat(context.arena, u8, &.{ "../", relative.slug, "/" }),
        });
        try html.element("em", .{}, relative.species.latin_name);
        try html.close("a");
        try html.close("li");
    }
    try html.close("ul");

    if (ordered.len > related_shown) {
        try html.open("p", .{ .class_ = "credit" });
        try html.open("a", .{
            .href = try std.mem.concat(context.arena, u8, &.{
                "../?q=", try percentEncode(context.arena, entry.family_fr),
            }),
        });
        try html.print("Voir les {d} essences de la famille", .{total});
        try html.close("a");
        try html.close("p");
    }
}

/// Percent-encoding for a query value. Everything outside the unreserved set is
/// encoded, which is stricter than necessary and never wrong.
fn percentEncode(arena: Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (value) |byte| switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(arena, byte),
        ' ' => try out.append(arena, '+'),
        else => try out.print(arena, "%{X:0>2}", .{byte}),
    };
    return out.items;
}

fn neighbours(html: Builder, context: Context, previous: ?Entry, next: ?Entry) !void {
    try html.open("nav", .{ .class_ = "neighbours", .aria_label = "Essences voisines" });
    for ([_]struct { entry: ?Entry, label: []const u8 }{
        .{ .entry = previous, .label = "Précédente" },
        .{ .entry = next, .label = "Suivante" },
    }) |side| {
        const neighbour = side.entry orelse {
            try html.element("span", .{}, "");
            continue;
        };
        try html.open("a", .{
            .href = try std.mem.concat(context.arena, u8, &.{ "../", neighbour.slug, "/" }),
        });
        try html.element("span", .{}, side.label);
        try html.element("em", .{}, neighbour.species.latin_name);
        try html.close("a");
    }
    try html.close("nav");
}

/// Must stay in step with `card` in web/src/search.js: the same markup is built
/// twice, once here and once in the browser.
fn card(html: Builder, context: Context, entry: Entry, root: []const u8) !void {
    try html.open("li", .{ .class_ = "card" });
    try html.open("a", .{
        .href = try std.mem.concat(context.arena, u8, &.{ root, "essences/", entry.slug, "/" }),
    });

    if (entry.hasImage()) {
        try html.empty("img", .{
            .class_ = "card__thumb",
            .src = try std.fmt.allocPrint(context.arena, "{s}img/{s}-{d}.webp", .{
                root, entry.slug, thumb_width,
            }),
            .srcset = try std.fmt.allocPrint(
                context.arena,
                "{s}img/{s}-{d}.webp {d}w, {s}img/{s}-{d}.webp {d}w",
                .{
                    root, entry.slug, thumb_width, thumb_width,
                    root, entry.slug, full_width,  full_width,
                },
            ),
            .sizes = "(min-width: 48rem) 16rem, 45vw",
            .alt = "",
            .loading = "lazy",
            .width = thumb_width,
            .height = thumb_height,
        });
    } else {
        try html.element("div", .{ .class_ = "card__thumb card__empty" }, "Aucune image libre");
    }

    try html.open("span", .{ .class_ = "card__name" });
    try html.element("em", .{}, entry.species.latin_name);
    try html.close("span");
    if (entry.searchable_names.len > 0) {
        try html.element("span", .{ .class_ = "card__fr" }, entry.searchable_names);
    }

    try html.close("a");
    try html.close("li");
}

fn searchForm(html: Builder, context: Context, root: []const u8, hint: []const u8) !void {
    try html.open("form", .{
        .class_ = "search",
        .role = "search",
        .data_search = true,
        .data_root = root,
        .data_corpus = try std.mem.concat(context.arena, u8, &.{ root, "data/search.json" }),
        .action = try std.mem.concat(context.arena, u8, &.{ root, "essences/" }),
        .method = "get",
    });
    try html.open("div", .{ .class_ = "search__field" });
    try html.empty("input", .{
        .type = "search",
        .name = "q",
        .placeholder = "chêne, Quercus, Fagacées…",
        .aria_label = "Rechercher une essence",
        .autocomplete = "off",
    });
    try html.element("button", .{ .type = "submit" }, "Rechercher");
    try html.close("div");
    try html.element("p", .{ .class_ = "search__hint" }, hint);
    try html.close("form");
}

/// Criteria filters. Hidden until JavaScript takes over: without it, ticking a
/// box would filter nothing, and an inert control is worse than none.
fn facets(html: Builder, legend: model.Legend) !void {
    try html.open("div", .{ .class_ = "filters", .data_filters = true, .hidden = true });
    inline for (facet_labels) |facet| {
        try html.open("fieldset", .{ .class_ = "facet", .data_facet = facet.key });
        try html.element("legend", .{}, facet.label);

        const group = @field(legend, facet.key);
        var shown: [8][]const u8 = undefined;
        var count: usize = 0;
        inline for (@typeInfo(@TypeOf(group)).@"struct".fields) |field| {
            const value = @field(group, field.name);
            var known = false;
            for (shown[0..count]) |already| known = known or std.mem.eql(u8, already, value);
            if (!known) {
                shown[count] = value;
                count += 1;
            }
        }
        for (shown[0..count]) |value| {
            try html.open("label", .{});
            try html.empty("input", .{ .type = "checkbox", .value = value });
            try html.text(" ");
            try html.text(value);
            try html.close("label");
        }
        try html.close("fieldset");
    }
    try html.element("button", .{ .type = "button", .data_reset = true }, "Tout effacer");
    try html.close("div");
}

// ------------------------------------------------------------------ pages

/// First sentence of the description, for the meta tag. Counted in codepoints,
/// and never cut mid-character.
pub fn summaryLeaky(arena: Allocator, entry: Entry) ![]const u8 {
    const descriptions = entry.species.enrichment.descriptions;
    if (descriptions.len == 0) {
        const names = if (entry.species.french_names.len > 0)
            try std.mem.join(arena, " · ", entry.species.french_names)
        else
            entry.species.latin_name;
        return std.mem.concat(arena, u8, &.{
            names,
            " — essence adaptée au changement climatique (CAUE 77).",
        });
    }

    const flattened = try arena.dupe(u8, descriptions[0].text);
    for (flattened) |*byte| {
        if (byte.* == '\n') byte.* = ' ';
    }

    const cut = codepointPrefix(flattened, 155);
    if (cut == flattened.len) return flattened;

    const head = flattened[0..cut];
    if (std.mem.lastIndexOf(u8, head, ". ")) |stop| {
        return std.mem.concat(arena, u8, &.{ head[0..stop], "." });
    }
    const space = std.mem.lastIndexOfScalar(u8, head, ' ') orelse head.len;
    return std.mem.concat(arena, u8, &.{ head[0..space], " […]" });
}

/// Byte length of the first `limit` codepoints, or the whole slice if shorter.
fn codepointPrefix(value: []const u8, limit: usize) usize {
    var at: usize = 0;
    var seen: usize = 0;
    while (at < value.len and seen < limit) : (seen += 1) {
        at += std.unicode.utf8ByteSequenceLength(value[at]) catch 1;
    }
    return @min(at, value.len);
}

pub fn speciesPage(
    out: *Writer,
    context: Context,
    entry: Entry,
    previous: ?Entry,
    next: ?Entry,
    relatives: []const usize,
) !void {
    const html: Builder = .{ .out = out };
    const root = "../../";
    const shell: Shell = .{
        .title = try std.mem.concat(context.arena, u8, &.{
            entry.species.latin_name,
            " — ",
            site_title,
        }),
        .summary = try summaryLeaky(context.arena, entry),
        .root = root,
        .tab = "essences/",
        .path = try std.mem.concat(context.arena, u8, &.{ "essences/", entry.slug, "/" }),
    };

    try shellOpen(html, context, shell);

    try html.open("h1", .{});
    try html.element("em", .{}, entry.species.latin_name);
    try html.close("h1");

    if (entry.species.french_names.len > 0) {
        try html.element(
            "p",
            .{ .class_ = "sheet__names" },
            try std.mem.join(context.arena, " · ", entry.species.french_names),
        );
    } else {
        try html.element(
            "p",
            .{ .class_ = "sheet__names sheet__names--missing" },
            "Sans nom français connu",
        );
    }

    try html.open("div", .{ .class_ = "sheet__top" });
    try illustration(html, context, entry, root);
    try characteristics(html, context, entry);
    try html.close("div");

    try warnings(html, entry);
    try html.element("h2", .{}, "Description");
    try description(html, context, entry);
    try otherImages(html, context, entry);
    try sameFamily(html, context, entry, relatives);
    try externalLinks(html, entry);
    try neighbours(html, context, previous, next);

    try shellClose(html, context, shell);
}

pub fn homePage(out: *Writer, context: Context, sample: []const Entry) !void {
    const html: Builder = .{ .out = out };
    const total = context.entries.len;
    const shell: Shell = .{
        .title = site_title,
        .summary = try std.fmt.allocPrint(
            context.arena,
            "{d} essences d'arbres adaptées au changement climatique en Seine-et-Marne : " ++
                "sol, exposition, description et photographie libres.",
            .{total},
        ),
        .root = "",
    };

    try shellOpen(html, context, shell);

    try html.open("div", .{ .class_ = "intro" });
    try html.element("h1", .{}, site_title);
    try html.open("p", .{});
    try html.print("{d}", .{total});
    try html.text(" essences d'arbres et d'arbustes recensées par le CAUE de Seine-et-Marne " ++
        "pour résister au climat des décennies à venir. Chaque fiche donne les exigences de " ++
        "sol, d'humidité et d'exposition, une description et une photographie libres.");
    try html.close("p");
    try html.close("div");

    try searchForm(html, context, "", "Cherchez par nom latin, nom français, famille " ++
        "botanique ou n'importe quel mot de la description.");
    try html.element("p", .{ .class_ = "count", .data_count = true }, "");

    try html.open("div", .{ .data_results = true, .hidden = true });
    try html.open("ul", .{ .class_ = "cards" });
    try html.close("ul");
    try html.close("div");

    try html.open("div", .{ .data_default = true });
    try html.element("h2", .{}, "Quelques essences");
    try html.open("ul", .{ .class_ = "cards" });
    for (sample) |entry| try card(html, context, entry, "");
    try html.close("ul");
    try html.open("p", .{});
    try html.element(
        "button",
        .{ .type = "button", .data_shuffle = true, .hidden = true },
        "Autres essences",
    );
    try html.close("p");
    try html.close("div");

    try html.open("p", .{});
    try html.open("a", .{ .href = "essences/" });
    try html.print("Parcourir les {d} essences", .{total});
    try html.close("a");
    try html.text(" · ");
    try html.link("credits/", "Sources et licences");
    try html.close("p");

    try shellClose(html, context, shell);
}

pub fn listPage(out: *Writer, context: Context) !void {
    const html: Builder = .{ .out = out };
    const shell: Shell = .{
        .title = try std.mem.concat(context.arena, u8, &.{ "Toutes les essences — ", site_title }),
        .summary = try std.fmt.allocPrint(
            context.arena,
            "Les {d} essences de la liste du CAUE 77, classées par disponibilité en pépinière.",
            .{context.entries.len},
        ),
        .root = "../",
        .tab = "essences/",
        .path = "essences/",
    };

    try shellOpen(html, context, shell);
    try html.element("h1", .{}, "Toutes les essences");
    try searchForm(html, context, "../", "La recherche porte sur les noms, la famille " ++
        "botanique et le texte des descriptions.");
    try facets(html, context.dataset.legend);
    try html.element("p", .{ .class_ = "count", .data_count = true }, "");

    try html.open("div", .{ .data_results = true, .hidden = true });
    try html.open("ul", .{ .class_ = "cards" });
    try html.close("ul");
    try html.close("div");

    try html.open("div", .{ .data_default = true });
    for ([_]struct { key: []const u8, title: []const u8 }{
        .{ .key = "disponible", .title = "Disponibles en pépinière" },
        .{ .key = "peu_disponible", .title = "Peu disponibles ou moins citées" },
    }) |group| {
        var count: usize = 0;
        for (context.entries) |entry| {
            if (std.mem.eql(u8, entry.species.availability, group.key)) count += 1;
        }
        try html.open("h2", .{});
        try html.text(group.title);
        try html.print(" — {d} essences", .{count});
        try html.close("h2");

        try html.open("ul", .{ .class_ = "cards" });
        for (context.entries) |entry| {
            if (!std.mem.eql(u8, entry.species.availability, group.key)) continue;
            try card(html, context, entry, "../");
        }
        try html.close("ul");
    }
    try html.close("div");

    try shellClose(html, context, shell);
}

pub fn notFoundPage(out: *Writer, context: Context, base: []const u8) !void {
    const html: Builder = .{ .out = out };
    const shell: Shell = .{
        .title = try std.mem.concat(context.arena, u8, &.{ "Page introuvable — ", site_title }),
        .summary = "Cette adresse ne correspond à aucune page du site.",
        .root = base,
    };

    try shellOpen(html, context, shell);
    try html.element("h1", .{}, "Page introuvable");
    try html.open("div", .{ .class_ = "prose" });
    try html.element("p", .{}, "Cette adresse ne correspond à aucune essence.");
    try html.open("p", .{});
    try html.link(
        try std.mem.concat(context.arena, u8, &.{ base, "essences/" }),
        "Parcourir toutes les essences",
    );
    try html.close("p");
    try html.close("div");
    try shellClose(html, context, shell);
}

pub fn creditsPage(out: *Writer, context: Context) !void {
    const html: Builder = .{ .out = out };
    const source = context.dataset.source;
    const coverage = context.dataset.coverage;
    const shell: Shell = .{
        .title = try std.mem.concat(context.arena, u8, &.{ "Sources et licences — ", site_title }),
        .summary = "Provenance, licences et attribution image par image des contenus " ++
            "réunis sur ce site.",
        .root = "../",
        .tab = "credits/",
        .path = "credits/",
    };

    try shellOpen(html, context, shell);
    try html.element("h1", .{}, "Sources et licences");
    try html.open("div", .{ .class_ = "prose" });
    try html.element("p", .{}, "Ce site compile des contenus d'origines distinctes. Cette " ++
        "page en donne la provenance complète et les obligations qui en découlent ; elle est " ++
        "générée à partir des mêmes données que les fiches, elle ne peut donc pas en diverger.");
    try html.close("div");

    try html.element("h2", .{}, "Données de base");
    try html.open("div", .{ .class_ = "prose" });
    try html.open("p", .{});
    try html.text("La liste des essences est extraite de « ");
    try html.text(source.document);
    try html.text(" » du ");
    try html.text(source.publisher);
    try html.text(" (");
    try html.text(source.date);
    try html.text("), pages ");
    try html.text(source.pdf_pages);
    try html.text(".");
    try html.close("p");
    try html.element("p", .{}, credits.source_notice);
    try html.open("ul", .{});
    try html.open("li", .{});
    try html.text("Présentation et téléchargement : ");
    try html.link(source.url, "Société française d'arboriculture");
    try html.close("li");
    try html.open("li", .{});
    try html.text("Lecture en ligne : ");
    try html.link(source.reader_url, "la fiche conseil sur Calaméo");
    try html.close("li");
    try html.close("ul");
    try html.close("div");

    try html.element("h2", .{}, "Sources de l'enrichissement");
    try html.open("div", .{ .class_ = "table-wrap" });
    try html.open("table", .{});
    try tableHead(html, &.{ "Source", "Apport", "Licence" });
    try html.open("tbody", .{});
    for (context.dataset.references.map.values()) |reference| {
        try html.open("tr", .{});
        try html.open("td", .{});
        try html.link(reference.url, reference.name);
        try html.close("td");
        try html.element("td", .{}, reference.usage);
        try html.element("td", .{}, reference.licence);
        try html.close("tr");
    }
    try html.close("tbody");
    try html.close("table");
    try html.close("div");

    try html.element("h2", .{}, "Licences retenues");
    try html.open("div", .{ .class_ = "table-wrap" });
    try html.open("table", .{});
    try tableHead(html, &.{ "Licence", "Attribution", "Partage à l'identique", "Commercial", "Images" });
    try html.open("tbody", .{});
    var licences = context.dataset.licences.map.iterator();
    while (licences.next()) |slot| {
        const licence = slot.value_ptr.*;
        try html.open("tr", .{});
        try html.open("td", .{});
        try html.open("a", .{ .href = licence.url, .rel = "license" });
        try html.text(licence.name);
        try html.close("a");
        try html.close("td");
        try html.element("td", .{}, if (licence.attribution) "oui" else "non");
        try html.element("td", .{}, if (licence.share_alike) "oui" else "non");
        try html.element("td", .{}, if (licence.commercial) "oui" else "non");
        try html.open("td", .{});
        try html.print("{d}", .{credits.countByLicence(context.dataset, slot.key_ptr.*)});
        try html.close("td");
        try html.close("tr");
    }
    try html.close("tbody");
    try html.close("table");
    try html.close("div");

    try html.element("h2", .{}, "Conséquences pour la réutilisation");
    try html.open("ol", .{ .class_ = "prose" });
    for (credits.consequences) |consequence| {
        try html.open("li", .{});
        try html.open("strong", .{});
        try html.text(consequence.title);
        try html.text(".");
        try html.close("strong");
        try html.text(" ");
        try html.text(consequence.body);
        try html.close("li");
    }
    try html.close("ol");

    try html.element("h2", .{}, "Couverture");
    try html.open("ul", .{ .class_ = "prose" });
    try html.open("li", .{});
    try html.print("{d} essences sur {d} ont une description, dont {d} en français.", .{
        coverage.with_description, coverage.total, coverage.french_description,
    });
    try html.close("li");
    try html.open("li", .{});
    try html.print("{d} ont une photographie sous licence libre.", .{coverage.with_image});
    try html.close("li");
    try html.open("li", .{});
    try html.print(
        "{d} fiches décrivent l'espèce parente et {d} le genre : c'est signalé sur la fiche concernée.",
        .{ coverage.fallback_parent_species, coverage.fallback_genus },
    );
    try html.close("li");
    try html.close("ul");

    const attributions = try credits.attributionsLeaky(context.arena, context.dataset);
    try html.open("h2", .{});
    try html.print("Attribution des {d} images", .{attributions.len});
    try html.close("h2");
    try html.open("div", .{ .class_ = "table-wrap" });
    try html.open("table", .{});
    try tableHead(html, &.{ "Essence", "Auteur", "Licence", "Source" });
    try html.open("tbody", .{});
    for (attributions) |line| {
        try html.open("tr", .{});
        try html.open("td", .{});
        try html.element("em", .{}, line.latin_name);
        try html.close("td");
        try html.element("td", .{}, if (line.author.len > 0) line.author else "—");
        try html.open("td", .{});
        try html.open("a", .{ .href = line.licence_url, .rel = "license" });
        try html.text(line.licence_name);
        try html.close("a");
        try html.close("td");
        try html.open("td", .{});
        try html.link(line.source_url, "fichier source");
        try html.close("td");
        try html.close("tr");
    }
    try html.close("tbody");
    try html.close("table");
    try html.close("div");

    try shellClose(html, context, shell);
}

fn tableHead(html: Builder, columns: []const []const u8) !void {
    try html.open("thead", .{});
    try html.open("tr", .{});
    for (columns) |column| try html.element("th", .{}, column);
    try html.close("tr");
    try html.close("thead");
}

const testing_gpa = std.testing.allocator;

test "a summary is cut at a sentence, never mid-character" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const long = "Le chêne pédonculé est un arbre. " ** 12;
    var species: model.EnrichedSpecies = undefined;
    species.french_names = &.{};
    species.latin_name = "Quercus robur";
    species.enrichment.descriptions = &.{.{
        .language = "fr",
        .page_title = "Chêne",
        .text = long,
        .url = "",
        .source = "wikipedia",
        .licence = "cc-by-sa",
        .attribution = "",
        .scope = "taxon_exact",
    }};

    const entry: Entry = .{
        .species = &species,
        .slug = "quercus-robur",
        .primary_image = null,
        .searchable_names = "",
        .family = "Fagaceae",
        .family_fr = "Fagacées",
        .french_description = long,
    };

    const summary = try summaryLeaky(arena, entry);
    try std.testing.expect(std.mem.endsWith(u8, summary, "."));
    try std.testing.expect(std.unicode.utf8ValidateSlice(summary));
    try std.testing.expect(summary.len < long.len);
}

test "codepointPrefix counts characters, not bytes" {
    // Six characters, seven bytes: the accented one takes two.
    try std.testing.expectEqual(@as(usize, 7), codepointPrefix("Chêne!", 6));
    try std.testing.expectEqual(@as(usize, 2), codepointPrefix("Chêne!", 2));
    // Three two-byte characters.
    try std.testing.expectEqual(@as(usize, 4), codepointPrefix("ééé", 2));
    try std.testing.expectEqual(@as(usize, 6), codepointPrefix("ééé", 9));
}

test "query values are percent-encoded" {
    var arena_state: std.heap.ArenaAllocator = .init(testing_gpa);
    defer arena_state.deinit();

    try std.testing.expectEqualStrings(
        "Fagac%C3%A9es",
        try percentEncode(arena_state.allocator(), "Fagacées"),
    );
    try std.testing.expectEqualStrings(
        "a+b%26c",
        try percentEncode(arena_state.allocator(), "a b&c"),
    );
}

test "a shrunk derivative keeps its aspect ratio, and an enlarged one is left alone" {
    const wide: model.Image = .{
        .source = "commons",
        .url = "",
        .source_url = "",
        .width = 1000,
        .height = 800,
        .author = "",
        .credit = "",
        .licence = "cc-by",
        .licence_url = "",
        .scope = "taxon_exact",
        .primary = true,
    };
    try std.testing.expectEqual(Size{ .width = 500, .height = 400 }, derivedSize(wide, 500));

    var small = wide;
    small.width = 300;
    small.height = 200;
    try std.testing.expectEqual(Size{ .width = 300, .height = 200 }, derivedSize(small, 500));
}
