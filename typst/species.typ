// Fiches d'essences adaptées au changement climatique : une page par arbre, deux au plus
// quand la description est longue (le garde-fou est `excerpt`).
//
// Compilation : typst compile --root . typst/species.typ out/species.pdf
// Les données viennent de data/species-enriched.json, les images de img/.

#let dataset = json("/data/species-enriched.json")

#let SERIF = ("Libertinus Serif", "New Computer Modern", "Charter")
#let SANS = ("Inter", "Avenir Next", "Helvetica Neue")

#let ACCENT = rgb("#2f5d3f")
#let INK = rgb("#1c1c1a")
#let MUTED = rgb("#6f7570")
#let PAPER = rgb("#f4f2ec")

#set document(
  title: dataset.source.title,
  author: "CAUE 77 — enrichi depuis Wikipédia, Wikimedia Commons et iNaturalist",
)
#set text(font: SERIF, size: 10pt, lang: "fr", fill: INK)
#set par(justify: true, leading: 0.62em)

// ---------------------------------------------------------------- composants

#let tag(body) = text(font: SANS, size: 7pt, weight: "medium", fill: MUTED,
  tracking: 0.06em, upper(body))

#let chip(body) = box(
  fill: PAPER, inset: (x: 5pt, y: 3pt), radius: 2pt, outset: (y: 1pt),
  text(font: SANS, size: 8pt, fill: INK, body),
)

/// Une ligne du tableau de caractéristiques ; `values` peut être vide.
#let feature(name, values, code: none) = {
  if values == none or values == () or values == "" { return }
  let list = if type(values) == array { values } else { (values,) }
  (
    tag(name),
    {
      list.map(chip).join(h(3pt))
      if code != none [ #h(4pt) #text(font: SANS, size: 7pt, fill: MUTED)[#code] ]
    },
  )
}

/// Crédit d'une image ou d'une description, avec sa licence.
#let credit(author, licence, url) = {
  let name = dataset.licences.at(licence, default: (name: licence)).name
  let mention = if author != none and author != "" [#author — #name] else [#name]
  text(font: SANS, size: 6.5pt, fill: MUTED, if url != none { link(url, mention) } else { mention })
}

#let illustration(species) = {
  let images = species.enrichment.images
  if images.len() == 0 {
    return block(width: 100%, height: 11cm, fill: PAPER, radius: 3pt,
      align(center + horizon, text(font: SANS, size: 8pt, fill: MUTED)[Aucune image libre]))
  }
  let primary = images.first()
  block(width: 100%)[
    #block(width: 100%, height: 11cm, fill: PAPER, radius: 3pt, clip: true,
      image("/" + primary.local_file, width: 100%, height: 100%, fit: "cover"))
    #v(3pt)
    #credit(primary.author, primary.licence, primary.source_url)
  ]
}

#let characteristics(species) = {
  let taxon = species.enrichment.taxon
  let height = if species.height_m != none [#species.height_m m] else { none }
  let cells = ()
  cells += feature("Hauteur adulte", height)
  cells += feature("Sol", species.acidity, code: species.codes.acidity)
  cells += feature("Humidité", species.moisture, code: species.codes.moisture)
  cells += feature("Exposition", species.exposure, code: species.codes.exposure)
  cells += feature("Particularités", species.traits, code: species.codes.traits)
  cells += feature("Famille", if taxon != none { taxon.family })
  cells += feature("Disponibilité", if species.availability == "disponible" {
    "disponible en pépinière"
  } else { "peu disponible" })

  grid(columns: (auto, 1fr), row-gutter: 9pt, column-gutter: 10pt, ..cells)
}

#let warnings(species) = {
  let messages = species.enrichment.warnings
  if messages.len() == 0 { return }
  block(width: 100%, inset: (x: 7pt, y: 5pt), radius: 2pt,
    fill: rgb("#fdf6e3"), stroke: (left: 2pt + rgb("#d9b96a")),
    text(font: SANS, size: 7.5pt, fill: rgb("#6b5720"), messages.join([ · ])))
}

/// Tronque au dernier point avant `maxi` : une fiche peut tenir sur deux pages, pas plus.
#let excerpt(body, maxi: 4000) = {
  let clusters = body.clusters()
  if clusters.len() <= maxi { return body }
  let head = clusters.slice(0, maxi).join()
  let stops = head.matches(regex("[.!?»][ \n]"))
  if stops.len() > 0 { head.slice(0, stops.last().end).trim() + " […]" } else { head + " […]" }
}

#let LANGUAGES = (en: "l'anglais", es: "l'espagnol", de: "l'allemand")

#let description(species) = {
  let entries = species.enrichment.descriptions
  if entries.len() == 0 { return }
  let entry = entries.first()
  let origin = entry.at("translated_from", default: none)
  block(width: 100%)[
    #for (index, paragraph) in excerpt(entry.text).split("\n").enumerate() {
      if paragraph.trim() == "" { continue }
      if index > 0 { parbreak() }
      paragraph
    }
    #v(5pt)
    #if origin == none {
      credit("Wikipédia (" + entry.language + ") — " + entry.page_title, entry.licence, entry.url)
    } else {
      credit("Wikipédia — " + origin.page_title + ", traduit de "
             + LANGUAGES.at(origin.language, default: "sa langue d'origine"),
             entry.licence, origin.url)
    }
  ]
}

#let links(species) = {
  let references = species.enrichment.links
  if references.len() == 0 { return }
  block(width: 100%, stroke: (top: 0.4pt + MUTED), inset: (top: 6pt),
    text(font: SANS, size: 7pt, fill: MUTED,
      references.map(reference => link(reference.url, reference.label)).join([ · ])))
}

#let sheet(species) = {
  heading(level: 2, species.latin_name)

  block(width: 100%, below: 14pt)[
    #if species.french_names.len() > 0 [
      #text(font: SANS, size: 11pt, fill: ACCENT, species.french_names.join(" · "))
    ] else [
      #text(font: SANS, size: 9pt, fill: MUTED)[Sans nom français connu]
    ]
  ]

  grid(columns: (1fr, 1fr), column-gutter: 16pt,
    illustration(species),
    characteristics(species))

  v(14pt)
  warnings(species)
  v(8pt)
  description(species)
  v(1fr)
  links(species)
}

// ------------------------------------------------------------------ document

#set page(
  paper: "a4",
  margin: (x: 2.2cm, top: 2.2cm, bottom: 1.8cm),
  footer: context {
    set text(font: SANS, size: 7pt, fill: MUTED)
    grid(columns: (1fr, auto),
      align(left)[Liste indicative d'essences adaptées aux changements climatiques — CAUE 77],
      align(right)[#counter(page).display("1")])
  },
)

#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  block(width: 100%, above: 0pt, below: 24pt)[
    #text(font: SANS, size: 8pt, fill: ACCENT, tracking: 0.12em)[#upper(it.body)]
    #v(4pt)
    #line(length: 100%, stroke: 0.8pt + ACCENT)
  ]
}
#show heading.where(level: 2): it => block(width: 100%, below: 5pt,
  text(font: SERIF, size: 21pt, style: "italic", weight: "medium", fill: INK, it.body))

// Couverture
// Les parenthèses sont nécessaires : sans elles, le retour à la ligne clôt l'expression.
#let showcase = (dataset.species
  .filter(species => species.enrichment.images.len() > 0)
  .map(species => species.enrichment.images.first().local_file))

#page(margin: 0pt, footer: none)[
  #place(top + left, rect(width: 100%, height: 100%, fill: PAPER))
  #place(top + left, grid(
    columns: (1fr,) * 5,
    ..range(5).map(rank => block(width: 100%, height: 9.5cm, clip: true,
      image("/" + showcase.at(rank * int(showcase.len() / 5)),
            width: 100%, height: 100%, fit: "cover"))),
  ))
  #place(top + left, dy: 9.5cm, rect(width: 100%, height: 2pt, fill: ACCENT))
  #block(width: 100%, height: 100%, inset: (x: 2.6cm))[
    #v(11.5cm)
    #set par(justify: false, leading: 0.5em)
    #text(font: SANS, size: 9pt, fill: ACCENT, tracking: 0.16em)[#upper("CAUE de Seine-et-Marne")]
    #v(0.9cm)
    #text(font: SERIF, size: 32pt, weight: "medium")[
      Essences potentiellement adaptées aux changements climatiques
    ]
    #v(0.7cm)
    #text(font: SANS, size: 11pt, fill: MUTED)[
      #dataset.species_count fiches illustrées, du sapin du Colorado au jujubier
    ]
    #v(1fr)
    #block(width: 82%, below: 3cm)[
      #text(font: SANS, size: 7.5pt, fill: MUTED)[
        Données extraites de
        #link(dataset.source.url)[« #dataset.source.document »]
        (#dataset.source.publisher, #dataset.source.date), pages #dataset.source.pdf_pages.
        #linebreak()
        Descriptions issues de Wikipédia (CC BY-SA 4.0), images de Wikimedia Commons et
        iNaturalist sous les licences indiquées sur chaque fiche.
        Taxonomie GBIF, identifiants Wikidata.
      ]
    ]
  ]
]

// Sommaire
#page[
  #text(font: SANS, size: 8pt, fill: ACCENT, tracking: 0.12em)[#upper("Sommaire")]
  #v(4pt)
  #line(length: 100%, stroke: 0.8pt + ACCENT)
  #v(14pt)
  #columns(2, gutter: 14pt)[
    #set text(size: 8pt)
    #show outline.entry.where(level: 2): it => text(style: "italic", it)
    #show outline.entry.where(level: 1): it => {
      v(6pt, weak: true)
      text(font: SANS, size: 7pt, fill: ACCENT, tracking: 0.08em, weight: "medium", it)
    }
    #outline(title: none, depth: 2, indent: 0pt)
  ]
]

#let sections = (
  ("disponible", "Essences disponibles en pépinières"),
  ("peu_disponible", "Essences peu disponibles ou moins citées"),
)

#for (key, title) in sections {
  heading(level: 1, title)
  let selection = dataset.species.filter(species => species.availability == key)
  for (index, species) in selection.enumerate() {
    if index > 0 { pagebreak() }
    sheet(species)
  }
}

// Crédits
#pagebreak()
#heading(level: 1, "Sources et licences")

// Compté sur les données plutôt qu'écrit en dur : la phrase ci-dessous suit le jeu d'images.
// Parenthèses obligatoires, comme pour `showcase` : sans elles le retour à la ligne clôt
// l'expression et le reste part en contenu — 98 pages de dictionnaires bruts.
#let noncommercial = (dataset.species
  .map(species => species.enrichment.images.filter(im => im.primary))
  .flatten()
  .filter(im => im.licence.starts-with("cc-by-nc"))
  .len())

#set text(size: 9pt)
La liste des essences provient de « #dataset.source.document »
(#dataset.source.publisher, #dataset.source.date), pages #dataset.source.pdf_pages. Ce PDF
n'est pas redistribué : il reste la propriété du CAUE de Seine-et-Marne, et se récupère sur
#link(dataset.source.url)[le site de la Société française d'arboriculture] ou se consulte
#link(dataset.source.reader_url)[en ligne].

#v(8pt)
Ce document compile des contenus de plusieurs origines. Les descriptions proviennent de
Wikipédia et sont diffusées sous licence CC BY-SA 4.0 : leur réutilisation impose de citer
l'article et de partager à l'identique. Chaque image porte l'auteur et la licence indiqués
sous la photographie ; #noncommercial d'entre elles sont sous licence non commerciale
(CC BY-NC), ce qui interdit toute exploitation commerciale de ce document en l'état.

#v(10pt)
#table(
  columns: (auto, 1fr, auto),
  stroke: none,
  inset: (x: 0pt, y: 5pt),
  table.hline(stroke: 0.4pt + MUTED),
  ..dataset.references.values().map(reference => (
    text(font: SANS, size: 8pt, weight: "medium", reference.name),
    text(size: 8.5pt, reference.usage),
    text(font: SANS, size: 8pt, fill: MUTED, reference.licence),
  )).flatten(),
  table.hline(stroke: 0.4pt + MUTED),
)

#v(14pt)
#text(font: SANS, size: 8pt, fill: ACCENT, tracking: 0.1em)[#upper("Couverture des données")]
#v(6pt)
#set text(size: 8.5pt)
- #dataset.coverage.with_description fiches sur #dataset.coverage.total ont une
  description, dont #dataset.coverage.french_description en français.
- #dataset.coverage.with_image ont une image sous licence libre.
- Les noms sont tous résolus sur le référentiel taxonomique GBIF ;
  #dataset.coverage.fallback_parent_species fiches décrivent l'espèce parente et
  #dataset.coverage.fallback_genus le genre, ce qui est signalé sur la fiche concernée.
