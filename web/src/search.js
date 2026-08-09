// Full-text search, criteria filters and the reshuffle button, client side.
//
// The corpus (data/search.json) is written by `tree-climate site` and fetched
// lazily, on first real need: a page nobody searches downloads nothing extra.
// MiniSearch itself is bundled, so there is no CDN to be blocked and no offline
// degradation to design around.
//
// Everything here is progressive enhancement. Without JavaScript the cards and
// the full list are still server-rendered and navigable; the filters and the
// reshuffle button stay hidden, because offering a control that does nothing is
// worse than not offering it.

import MiniSearch from "minisearch";

const form = document.querySelector("[data-search]");
if (form) start(form);

function start(form) {
  const field = form.querySelector("input[type=search]");
  const resultsBox = document.querySelector("[data-results]");
  const defaultBox = document.querySelector("[data-default]");
  const counter = document.querySelector("[data-count]");
  const shuffleButton = document.querySelector("[data-shuffle]");
  const filtersBox = document.querySelector("[data-filters]");
  const root = form.dataset.root;

  let corpus = null;
  let engine = null;

  const fold = (value) =>
    value.toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "");

  /** Loads the corpus once and builds the index. */
  async function prepare() {
    if (corpus) return;
    corpus = await (await fetch(form.dataset.corpus)).json();
    engine = new MiniSearch({
      fields: ["latin_name", "french_names", "family", "family_fr", "text"],
      storeFields: ["slug"],
      processTerm: (term) => (term.length > 1 ? fold(term) : null),
    });
    engine.addAll(corpus);
  }

  function search(query) {
    const found = engine.search(query, {
      // No fuzzy matching: in botanical nomenclature one letter separates two
      // real families, and "Fagacees" was bringing back Fabaceae -- legumes
      // instead of oaks. Prefix matching covers typing in progress, and finding
      // nothing beats confidently offering the wrong family.
      prefix: (term) => term.length >= 3,
      fuzzy: false,
      combineWith: "AND",
      boost: { latin_name: 4, french_names: 4, family: 2, family_fr: 2 },
    });
    const bySlug = new Map(corpus.map((species) => [species.slug, species]));
    return found.map((hit) => bySlug.get(hit.slug));
  }

  /** The ticked criteria, by facet key. */
  function criteria() {
    const active = new Map();
    if (!filtersBox) return active;
    for (const block of filtersBox.querySelectorAll("[data-facet]")) {
      const chosen = [...block.querySelectorAll("input:checked")].map((box) => box.value);
      if (chosen.length) active.set(block.dataset.facet, chosen);
    }
    return active;
  }

  /** AND between criteria, OR within one: "sun or half-sun, and acid soil". */
  function matches(species, active) {
    for (const [key, wanted] of active) {
      const held = species[key] || [];
      if (!wanted.some((value) => held.includes(value))) return false;
    }
    return true;
  }

  /** Built through the DOM API, never innerHTML: these names come from a PDF,
      from GBIF and from Wikipedia, and none of those is ours to trust.
      Must stay in step with `card` in src/site/page.zig. */
  function card(species) {
    const item = document.createElement("li");
    item.className = "card";

    const anchor = document.createElement("a");
    anchor.href = `${root}essences/${species.slug}/`;

    if (species.image) {
      const thumb = document.createElement("img");
      thumb.className = "card__thumb";
      thumb.src = `${root}img/${species.slug}-320.webp`;
      thumb.srcset =
        `${root}img/${species.slug}-320.webp 320w, ` +
        `${root}img/${species.slug}-500.webp 500w`;
      thumb.sizes = "(min-width: 48rem) 16rem, 45vw";
      thumb.alt = "";
      thumb.loading = "lazy";
      thumb.width = 320;
      thumb.height = 240;
      anchor.append(thumb);
    } else {
      const empty = document.createElement("div");
      empty.className = "card__thumb card__empty";
      empty.textContent = "Aucune image libre";
      anchor.append(empty);
    }

    const name = document.createElement("span");
    name.className = "card__name";
    const latin = document.createElement("em");
    latin.textContent = species.latin_name;
    name.append(latin);
    anchor.append(name);

    if (species.french_names) {
      const french = document.createElement("span");
      french.className = "card__fr";
      french.textContent = species.french_names;
      anchor.append(french);
    }

    item.append(anchor);
    return item;
  }

  function showDefault() {
    resultsBox.hidden = true;
    if (defaultBox) defaultBox.hidden = false;
    if (counter) counter.textContent = "";
  }

  /** Mirrors the state into the URL so a filtered view stays shareable. */
  function remember(query, active) {
    const parameters = new URLSearchParams();
    if (query) parameters.set("q", query);
    for (const [key, values] of active) parameters.set(key, values.join(","));
    const rest = parameters.toString();
    history.replaceState(null, "", rest ? `?${rest}` : location.pathname);
  }

  async function respond() {
    const query = field.value.trim();
    const active = criteria();
    remember(query, active);
    if (query.length < 2 && active.size === 0) return showDefault();

    await prepare();
    const base = query.length >= 2 ? search(query) : corpus;
    const found = base.filter((species) => matches(species, active));

    resultsBox.querySelector("ul").replaceChildren(...found.map(card));
    if (counter) {
      counter.textContent =
        found.length === 0
          ? "Aucune essence ne correspond à cette recherche"
          : `${found.length} essence${found.length > 1 ? "s" : ""}`;
    }
    resultsBox.hidden = false;
    if (defaultBox) defaultBox.hidden = true;
  }

  let timer;
  field.addEventListener("input", () => {
    clearTimeout(timer);
    timer = setTimeout(respond, 150);
  });
  form.addEventListener("submit", (event) => {
    event.preventDefault();
    respond();
  });

  if (filtersBox) {
    filtersBox.hidden = false;
    filtersBox.addEventListener("change", respond);
    filtersBox.querySelector("[data-reset]").addEventListener("click", () => {
      filtersBox.querySelectorAll("input:checked").forEach((box) => (box.checked = false));
      field.value = "";
      respond();
    });
  }

  if (shuffleButton) {
    shuffleButton.hidden = false;
    shuffleButton.addEventListener("click", async () => {
      await prepare();
      const shuffled = corpus.slice();
      for (let rank = shuffled.length - 1; rank > 0; rank--) {
        const drawn = Math.floor(Math.random() * (rank + 1));
        [shuffled[rank], shuffled[drawn]] = [shuffled[drawn], shuffled[rank]];
      }
      field.value = "";
      defaultBox.querySelector("ul").replaceChildren(...shuffled.slice(0, 4).map(card));
      showDefault();
    });
  }

  // Allows landing on an already-filtered view: /essences/?q=chene&exposure=soleil
  const initial = new URLSearchParams(location.search);
  if ([...initial.keys()].length) {
    field.value = initial.get("q") || "";
    if (filtersBox) {
      for (const block of filtersBox.querySelectorAll("[data-facet]")) {
        const wanted = (initial.get(block.dataset.facet) || "").split(",");
        block
          .querySelectorAll("input")
          .forEach((box) => (box.checked = wanted.includes(box.value)));
      }
    }
    respond();
  }
}
