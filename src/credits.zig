//! The legal wording and the attribution figures, written once and rendered
//! twice: as docs/CREDITS.md and as the site's /credits/ page.
//!
//! Two renderings of one set of facts. Anything stated in prose in only one of
//! them is a fact that can drift.

const std = @import("std");
const model = @import("model.zig");

/// The PDF is not redistributed, so citing where to obtain it is the only way
/// to keep the extraction verifiable without appropriating a document that is
/// not ours.
pub const source_notice =
    "Le PDF n'est pas redistribué dans ce dépôt : il reste la propriété du " ++
    "CAUE de Seine-et-Marne. L'extraction reste vérifiable en le récupérant à la source.";

pub const Consequence = struct { title: []const u8, body: []const u8 };

pub const consequences = [_]Consequence{
    .{
        .title = "Usage non commercial",
        .body = "Le jeu d'images retenu inclut des photographies sous licence CC BY-NC et " ++
            "CC BY-NC-SA : toute publication qui les affiche doit rester non commerciale. " ++
            "Le code de licence est stocké image par image ; un site commercial peut les " ++
            "filtrer à la génération en ne conservant que les licences marquées commerciales.",
    },
    .{
        .title = "Partage à l'identique",
        .body = "Les descriptions proviennent de Wikipédia (CC BY-SA 4.0). Toute page qui les " ++
            "reprend doit citer l'article, lier la licence, et être elle-même diffusée sous " ++
            "CC BY-SA 4.0.",
    },
    .{
        .title = "Attribution par image",
        .body = "Chaque image porte son auteur, sa licence et l'URL de sa page source ; ces " ++
            "trois mentions doivent accompagner l'image affichée.",
    },
    .{
        .title = "Sites consultés sans reprise de contenu",
        .body = "snv.jussieu.fr/bmedia/arbres (Sorbonne Université, tous droits réservés) et " ++
            "climessences.fr (CNPF/ONF) ne sont cités qu'en lien : aucun texte ni aucune " ++
            "image n'en est repris.",
    },
};

/// One attribution line per primary image, independent of the output format.
pub const Attribution = struct {
    latin_name: []const u8,
    author: []const u8,
    licence_name: []const u8,
    licence_url: []const u8,
    source_url: []const u8,
};

/// Sorted by latin name, not by page order: this is a reference table, and a
/// reader looking for one species should not have to know which page it was on.
pub fn attributionsLeaky(
    arena: std.mem.Allocator,
    dataset: *const model.EnrichedDataset,
) ![]const Attribution {
    const ordered = try arena.dupe(model.EnrichedSpecies, dataset.species);
    std.mem.sort(model.EnrichedSpecies, ordered, {}, byLatinName);

    var lines: std.ArrayList(Attribution) = .empty;
    for (ordered) |species| {
        for (species.enrichment.images) |image| {
            if (!image.primary) continue;
            const licence = dataset.licences.map.get(image.licence);
            try lines.append(arena, .{
                .latin_name = species.latin_name,
                .author = image.author,
                .licence_name = if (licence) |present| present.name else image.licence,
                .licence_url = if (image.licence_url.len > 0)
                    image.licence_url
                else if (licence) |present| present.url else "",
                .source_url = if (image.source_url.len > 0) image.source_url else image.url,
            });
        }
    }
    return lines.items;
}

/// How many primary images carry each licence code.
fn byLatinName(_: void, a: model.EnrichedSpecies, b: model.EnrichedSpecies) bool {
    return std.mem.lessThan(u8, a.latin_name, b.latin_name);
}

pub fn countByLicence(dataset: *const model.EnrichedDataset, code: []const u8) usize {
    var total: usize = 0;
    for (dataset.species) |species| {
        for (species.enrichment.images) |image| {
            if (image.primary and std.mem.eql(u8, image.licence, code)) total += 1;
        }
    }
    return total;
}

pub fn totalPrimaryImages(dataset: *const model.EnrichedDataset) usize {
    var total: usize = 0;
    for (dataset.species) |species| {
        for (species.enrichment.images) |image| {
            if (image.primary) total += 1;
        }
    }
    return total;
}
