# AGENTS.md — `talk` Quarto reveal.js template

Reference for agents working on this template. This file describes the template **as it is now**. When a feature is added, changed or removed, edit the matching entry in place. It is not a changelog: never append history.

---

## 0. The two objectives (read first)

This project has two objectives. Both matter; they come one after the other.

1. **Rebuild the PowerPoint in Quarto (the past).** A converted deck must look and behave like its pptx: same layout, same clicks in the same order, same animations.
2. **A reusable template that humans maintain (the future).** Axel will write new decks by hand with this template. What matters there: the important features are kept, and a deck's `.qmd` is short, readable and easy to tune by a human (one block per object or per click, no generated noise). Anything that needs a lot of deck code becomes a template feature (a class, an attribute, a shortcode, a standard extension), so the deck itself stays small.

**Cascade.** First rebuild (objective 1); once a deck is rebuilt, generalise its code as much as possible (objective 2), keeping its look and clicks. When both conflict on a detail, prefer native Quarto/Markdown over pixel resemblance, but never change the click order or the animations.

**Current phase (PhD deck): objective 2.** `index.qmd` is rebuilt; now reduce its code and move repeated patterns into template features.

---

## 1. Rules for any change

1. **Quarto/reveal.js first.** Before building a feature, check whether Quarto, Pandoc, reveal.js or KaTeX already does it (docs, extensions, options). If it does, use it.
   - A thin wrapper is fine, like a LaTeX `\newcommand`: a class, a shortcode, a KaTeX macro, or a YAML default in `_extension.yml`.
   - Write custom Lua/JS/CSS only when nothing native exists.
2. **Factorise.** If a new feature resembles an existing one, extend or generalise the existing one rather than adding a parallel near-duplicate. Shared helpers already exist; reuse them:
   - `parse_steps` / `step_attrs`: click steps → fragment wrappers.
   - `color_value`: palette name or CSS colour.
   - `css_size`, `has_class`, `trim`.
   - JS: `measure`, `target` / `box` in the annotations module.
3. **The template is the test suite.** `tour/template.qmd` (`_extensions/tour/template.qmd` seen from a deck) shows every feature, one slide per feature group. Each slide has an `<!-- EXPECT: … -->` comment giving the expected behaviour. After **every** change to the extension:
   - render `template.qmd` (from a deck whose `_quarto.yml` lists `_extensions/tour/template.qmd`; and, if possible, `index.qmd`, the real deck);
   - check every slide and every click step against its EXPECT comment. The method so far: headless Chromium screenshots of each fragment step, compared before/after the change with a pixel diff;
   - tell the user explicitly which features fail, if any;
   - add a slide (with its EXPECT comment) to `template.qmd` for every new feature.
4. **Keep this file current** (section 3 table, section 4 notes, section 6 ideas) and keep `README.md` (human user guide, repository root) in sync.
5. **No deprecated spellings.** The template is young: when a syntax is replaced, remove the old one everywhere (filter, converter, template, docs) instead of keeping an alias.
6. **Decks are written by hand.** `index.qmd` was generated from the pptx by `tools/` (`_extensions/tools/` seen from a deck), but is now maintained by hand: edit it directly, never rebuild it. Write it for a human: one block per object or per click, native syntax (Markdown, quarto-arrows, Mermaid, includes) rather than SVG copies of PowerPoint shapes, no wrapper divs, no split runs. `tools/` stays for converting future talks.
7. **Line endings.** The user's working copy is on Windows (CRLF). Compare files ignoring `\r`, and write back with CRLF.

---

## 2. Architecture

**Repository = the `_extensions/` folder of a deck.** The template lives in its own repository (`quarto-talk`, to be published on GitHub), whose root holds the extension folders directly, because Quarto only finds a format in the `_extensions/` of the document's folder (or of its project), and nowhere else. Every deck (e.g. `phd-defense-quarto/`) is a sibling folder: `index.qmd`, `media/`, `refs.bib`, `_quarto.yml`, and `_extensions/` = a `git clone` of the repository (git-ignored by the deck). A template change made inside a deck is committed and pushed from `_extensions/`; other decks `git pull` there. `quarto add <user>/quarto-talk` also works (Quarto picks up `talk/` and `arrows/` at the repository root).

```
quarto-talk/           (cloned as <deck>/_extensions/)
  README.md            human user guide;  AGENTS.md  this file;  working_instructions.md  (Claude project)
  talk/                the extension (below)
  arrows/              quarto-arrows (Emil Hvitfeldt), vendored, not modified
  tools/               PowerPoint → template converter + shoot_steps.js (section 5)
  tour/                template.qmd (feature tour = test deck), its media/ and refs.bib.
                       It renders only from a deck whose _quarto.yml lists _extensions/tour/template.qmd
                       (a file under _extensions/ is otherwise outside the project); its YAML sets
                       html-math-method url ../talk/katex/ (the format's default path is relative to
                       a deck at the root of its folder).
talk/
  _extension.yml   format `talk-revealjs`: reveal options (1280×720, margin 0, no transition, slide numbers…),
                   KaTeX served locally (html-math-method url), filters: talk.lua, shortcode: audio.lua
  talk.lua         Pandoc filter: everything structural (see pipeline below)
  audio.lua        {{< audio >}} shortcode → speaker-icon span with data-audio… (resolved AFTER talk.lua)
  audio_icon.lua   the speaker SVG, loaded with dofile() by audio.lua and talk.lua
  talk.js          browser side, IIFE modules: (1) KaTeX patch + equation highlights,
                   (2) annotations layout, (3) audio + auto-animate matcher + letter-box bleed + keys,
                   (4) slide-number labels (Reveal.configure({slideNumber: fn}))
  talk.scss        theme (scss:defaults = palette, fonts; scss:rules = all styles, CSS variables)
  alphabetic.csl   biblatex-"alphabetic"-like CSL (label = citation-label)
  fonts/, fonts.css   Libre Franklin (woff2), loaded as an HTML dependency
  katex/           offline KaTeX (Quarto's revealjs math plugin is MathJax-2-only)
```

**`talk.lua` pipeline** (`function Pandoc(doc)`, order matters):

0. `title_slides` (fills / inserts the title slide, disables Quarto's).
1. Read YAML `talk:` (`section` incl. `style`, `colors`, `bullets`, `audio`, `slide-number`, `citations`, `highlight`) → CSS variables in a `<style>` in the header, `window.TalkConfig`, and the HTML dependency (talk.js, fonts).
2. `setup_citations` (labels, own-work set) → `fullcites`.
3. Walk `grid_box` (divided boxes → cell and line divs), `list_div` (`bullets=` → marker variables; `.incremental levels=N` → fragment divs in the items) and `box_attrs` (short attributes `left/top/right/bottom/width/height` on `.absolute`, `size` (pt), `color`, `background`, `align`, `border`, `radius`, `line-height`, `padding` → one `style=`, theme colour names → `var(--talk-*)`).
4. `process(blocks)`: split into slides; `take_appendix_marker` (an empty `::: {.appendix}` in a slide → every later slide gets `.additional`, except `.counted`; logged on stderr); `special_slide` (`.test-slide`, `.additional` → uncounted); heading `.incremental levels=N`; record sections for the TOC (`toc_record`); build section-header/summary pairs and side panels (`build_section`), or the simple style (header alone + `plain_summary`); `.toc-slide` gets a placeholder; append per-slide reference lists (`slide_refs_div`).
5. `fill_toc`: fills the placeholder or `::: {#toc}` (`toc_blocks`); then `push_transitions`.
6. `fill_refs`: fills `::: {#refs}`.
7. Walk `highlight_image` / `highlight_div` / `highlight_span` → walk `highlight_math` → walk `annotation`.
8. Walk `tilt` (3D) → `resolve_cites` (citations rendered by the filter itself).

---

## 3. Features: syntax → implementation

| Feature | Author syntax | Implementation |
|---|---|---|
| Push transition (PowerPoint "Push") | `push=up\|down\|left\|right` on a heading; YAML `talk: push-duration` (0.8 s); other native `transition=` still work | lua `push_transitions` (both slides get `data-transition="talk-push"` + `talk-push-in[-DIR]` / `talk-push-out[-DIR]`); scss `PUSH TRANSITION`; js module 5 `.talk-pushing` (hides section edge bars during the move); converter `<p:push dir>` → `push=` |
| Title slide | `## {.title-slide}` (optional `parts="title byline note date logos"`, heading text = title); YAML `title author institute subtitle date date-format`, `talk: title-slide: {note, logos, background, date}` or `false` | lua `title_slides` (first step of `Pandoc()`: fills `.ts-text` > `.ts-title/.ts-byline/.ts-note/.ts-date` and `.ts-logos`, inserts one after leading test slides if none, removes `meta.title` → `pagetitle` so Quarto's title block is off); scss `TITLE SLIDE` (`--ts-*` vars); converter: pptx title layout → `.title-slide` |
| Captioned pictures | `::: {.absolute .caption-top\|.caption-bottom left= top= size= color=}` + `![Caption](img){width= height=}` | native figure; scss `CAPTIONED PICTURES` (`figure {width: fit-content}` = the picture; figcaption absolutely placed outside it, centred on it, whatever the box's width); converter `tools/captions.py` |
| Theme colours | YAML `talk: colors: {background, text, title, bar, accent}`; one slide: native `background-color=` on the heading | `Pandoc()` → `--talk-*` vars; scss `THEME COLOURS` |
| Lists (PowerPoint master look, 5 distinct markers ■ – • ○ ►) | any Markdown list; per level N = 1–5 CSS vars `--talk-bN`, `-size`, `--talk-marN`, `--talk-indN`, `--talk-spcbN`, `--talk-spca`, `--talk-szN`, `--talk-stN` (depth 6–10 reuse levels 1–5, +48 px each); classes `.b-sq/.b-dash/.b-dot/.b-circ/.b-tri/.b-check/.b-arrow/.b-none` (+ level digit 0–4), `.no-bullets`; `bullets="■ – • ○ ►"` on a div; YAML `talk: bullets:` | scss `LISTS` (SCSS loop over depth 1–10 sets the vars on `ul`/`ol`, read by `li` and `li::before`); lua `bullet_vars`, `list_div`; converter treats the pptx master markers ■ – ■ – as default |
| List clicks | native `.incremental` / `.nonincremental` / `. . .`; `.incremental levels=N` (div or heading): only levels ≤ N are clicks | native Pandoc; lua `wrap_list`/`wrap_lists` (items → `div.fragment`); scss hides `li::before` while its inner fragment is hidden |
| Test slide, appendix | `## T {.test-slide}`; `::: {.appendix}` `:::` once (all later slides additional; `.counted` opts out), or `## T {.additional}` per slide; YAML `talk: slide-number: {test, additional}` (`{n}`) | lua `appendix`, `take_appendix_marker`, `special_slide` (→ `visibility=uncounted`); js module 4 `number()` (a paired summary takes its header's label) |
| Grid boxes (one box, several cells: matrices, bars, overlays, tensors) | on any div: `cols=5` / `cols="2 2 1 1"`, `rows=…` (equal or relative sizes), `lines=true` / `"2px accent"`, `hl="STEPS@CELL COLOUR"`; a list = cell texts row by row; `[x]{.cell …}` alone in an item = attributes of the whole cell (`.fragment`, `background=`, `hl=`, `data-id=` → the cell morphs alone). | lua `grid_box` (cells and lines = absolutely placed divs in % of the box; with a known width/height the boundaries are first snapped to whole px of the inner box (`snap`, size − 2 × border), so lines and highlights share the same pixels; `boundaries`/`grid_of`; keeps the grid as `grid-cols`/`grid-rows` and the inner size as `grid-inner` for `hl_host`), `area_style(area, g)` with uneven boundaries (whole px when `g.iw/g.ih` are known, else %); scss `GRID BOXES`; converter `tools/segments.py` |
| Short attributes, box defaults | `left= top= right= bottom= width= height=` (on `.absolute`), `size=` (pt), `color=`/`background=` (CSS or theme names `text title accent background bar`), `align=`, `border=`, `radius=`, `line-height=`, `padding=`; classes `.tb` (18 pt, black, inner margin), `.tb.body` (20 pt, text colour, lh 1.13), `.tb.ttl` (44 pt, title colour, lh 1.07), `.nowrap` | lua `box_attrs`; scss `.tb` rules + `--talk-pt` (1.24 px = 1 pt × 0.93); converter `tools/tidy.py` |
| Table of contents | `## T {.toc-slide}` or `::: {#toc}` `:::`; `.no-toc` on a section header | lua `toc_record`, `toc_blocks`, `fill_toc`; scss `TABLE OF CONTENTS` (basic look) |
| Section style | `section-style=full\|simple` on the header, YAML `talk: section: style:` | lua `section_style`, `plain_summary`, branch in `process`; scss `.talk-hidden-title` |
| Content area / left bar | Markdown slides start at `--talk-content-top` (180px), from `--talk-content-left` (144px) to `--talk-content-right` (60px) from the right edge; `.nobar` hides the bar | scss top rules |
| Section header → summary (Morph-like) | `## T {.section-header}` then `## T' {.section-summary}`; options as heading attrs or YAML `talk: section:` (`color, text-color, border-width, border-color, panel-width, title-size, summary-title-size, subtitle-size, panel-subtitle-size, ref-size, title-width, title-weight, panel-padding, panel-top, duration, easing`); `::: {.section-panel}`, `::: {.section-ref}` | lua `take_options`, `section_info`, `slide_attrs`, `text_blocks`, `wordify`, `build_section`; `style_of` / `Pandoc()` derive `summary-title-size` and `panel-subtitle-size` from `panel-width` (`PANEL_SIZES`, reference 440 px) when not given, and the header gets the summary's panel options (same layout for its ghost copy); scss `SECTION SLIDES` (panel text centred in the visible panel: `--sec-panel-text-width` = panel − border − 2 × padding); js `talkMatcher`, `updateBleed` |
| Side panel (no transition) | `## T {.side-panel}` | same code path, `kind = "panel"` |
| Slide counter | the summary is auto `visibility="uncounted"` (shares the header's number); no counter shown on a `.section-header` | `slide_attrs`; scss `:has(section.present.section-header) .slide-number` |
| Arrows, lines | `{{< arrow from="x,y" to="x,y" position="absolute" … >}}` (slide px; `to` = base of the head) | third-party extension `_extensions/arrows` (quarto-arrows, Emil Hvitfeldt), not modified |
| Diagrams | ```` ```{mermaid} ```` inside `::: {.absolute left= top= width= height=}` | Quarto Mermaid; scss `$mermaid-*` defaults + `DIAGRAMS` rules (svg fills the box; a slide holding an undrawn `pre.mermaid-js` is laid out while hidden, else Quarto draws an empty 16×16 chart); lua `mermaid_maths` (adds `forceLegacyMathML` to the chart's init directive: KaTeX HTML labels with the KaTeX fonts, `\mathscr`) |
| Click groups | `::: {.fragment [.fade-in-then-out] fragment-index=N}` around every object of that click | native; `fragment-index` → `data-fragment-index` by Pandoc; lua `clean()` and `tilt` strip/move both spellings |
| Boxes | `.box` (framed, background, text centred both ways, 18 pt black), `.filled` (PowerPoint default shape style: accent fill, `--talk-accent-dark` outline 3.67 px, background-coloured text); one-line objects as spans `[text]{.absolute .tb …}` | scss `BOXES AND SHAPES` (`display:block; align-content: unsafe center`, never flex: a flex span would stack its words and formulas); span boxes get `line-height: 1.3` like reveal's `<p>` |
| Shapes | `shape=arrow-right\|arrow-left\|arrow-up\|arrow-down\|shrink\|grow\|parallelogram\|cube` on any box; `head= shaft=` (%), `taper=` (%), `slant=` (%), `depth=` (px); `background=` fill, `border=` outline; `.box`/`.filled` give the defaults | lua `shape`, `shape_path` (SVG `svg.geom` behind the content, viewBox = box px or 100); cube: content padded into the front face |
| Block diagrams (horizontal) | `::: {.absolute .flow left= top= width= height= gap=}` + items `[$X$]{.box width=42 height=100% dim="ft"}`, `[Encoder]{shape=shrink …}`, `$\xrightarrow{a()}$`; `.dim-right` | scss `FLOW` (flex row on the `<p>`; `dim=` → `::before` label + `::after` arrow); lua `box_attrs` (width/height on spans, `gap` → `--flow-gap`) |
| Title position | `## Title {top= left= width= size=}` | lua `title_attrs` (→ `--title-*` on the section); scss h2 rule |
| Empty lines | `-` alone in a list (level by indentation), `&nbsp;` paragraph elsewhere | scss `EMPTY LINES` (`li:empty`, calibrated on the PowerPoint gaps); lua Para → `div.empty-line` |
| Recap of a built slide | `::: {.static}` (fragments removed; fade-outs dropped), typically around `{{< include _x.qmd >}}` | lua `static_block` (first walk) |
| Sound played at a click | `play=N` on an `.audio-btn` / `data-audio` span | lua `audio_play` (adds `[]{.fragment data-play=ID}`, id `talk-play-k` if none) |
| Motion path | `::: {.fragment .move fragment-index=N dx= dy=}` around objects | scss `.fragment.move` (absolute, inset 0; `translate(var(--dx,0), var(--dy,0))`); lua `box_attrs` dx/dy |
| Diagonal / sequence highlights | `hl="STEPS@diag c1 c2 …"` (cell k,k gets colour k), `@cols …`, `@rows …` | lua `hl_regions` (expands into one entry per cell) |
| Morph of any object | native: `auto-animate=true` on both slides + same `data-id` | reveal; custom matcher `talkMatcher` (slide-relative `measure`, zoom-aware, `IMG` key for wrapped images) |
| Clicks, motion path, delay | native `.fragment` + `data-fragment-index`; `.fragment.move` with `--dx/--dy`; `delay=S` on a fragment (appears S s after its click); `delay=end` (appears when the sound playing at its click ends or is stopped; at once if none plays) | reveal; scss `.fragment.move`; `delay` → `data-delay` (pandoc) → js module 6 sets `--talk-delay`, scss `transition-delay` on `.visible` only; `delay=end`: js audio module (3) adds `.talk-waiting` on `fragmentshown` (after that click's plays) if a sound plays, `releaseLater()` on the sounds' `ended`/`pause`/blocked, cleared on `fragmenthidden`/`slidechanged`; scss `.fragment.visible.talk-waiting` hidden; converter: a delayed entrance in a click that plays a sound → `delay=end` |
| Audio | `{{< audio file autoplay= delay= loop= volume= id= label= fragment= left= top= size= >}}`; any element `data-audio`, `data-autoplay`, `data-autoplay-delay`, `data-loop`, `data-volume`; triggers `[]{.fragment data-play="id"}`, `[]{.fragment data-stop-audio=true}`; key **A**; YAML `talk: audio:` | `audio.lua`; lua `audio_icon` (an empty span `.audio-btn` → icon; the converter writes `[]{.absolute .audio-btn left= top= data-audio=…}` instead of the pptx picture); icon size `--talk-audio-size` (2em, YAML `talk: audio: size`, `size=`), click area enlarged by padding; js audio module (`play`, `autoplayIn`, fragment events; one capture-phase click listener on `[data-audio]`); scss `AUDIO buttons`: cursor on any `[data-audio]`, hover zoom / playing glow on `.audio-btn` and `img[data-audio]` |
| Citations | `bibliography:`, `[@k]`, `[@a; @b]`, prefix/suffix, `@k` (in text), `[@k]{.fullcite}`, `[[@k]]{.refs-only}`, `{.no-slide-refs}`, `## … {.references-slide}` + `::: {#refs}`; YAML `talk: citations: {slide-refs, highlight-author}`; bib `shorthand` = label | lua `read_shorthands`, `alpha_label`, `setup_citations`, `entries_for` (mini `pandoc.utils.citeproc`), `render_cite`, `slide_refs_div`, `fill_refs`; `alphabetic.csl` |
| Highlights on objects | `hl="STEPS@AREA COLOUR; …"` on div / span / image. STEPS `n`, `n-m`, `n-`, `0`. AREA: none (whole), grid of the object (`cols=`/`rows=`) `@k`, `@k-l`, `@c,r`, `*`, or `@(x,y,w,h)` in % or px. Options `hl-color`, `hl-shape=round\|ellipse`, `hl-radius`, `hl-pad` (halo), `hl-opacity`, `hl-style=outline`. YAML `talk: highlight: {color, opacity, colors:{name: …}}`. Key **R** shows areas and grids | lua `hl_regions` (cells in whole px when the grid's inner size is known — `grid-inner`, set by `grid_box` and `highlight_image`; a cell is drawn 1 px under a right/bottom neighbour shown whenever it is, `--hl-dx/--hl-dy`, and the regions are ordered so the neighbour is painted after it), `area_style`, `hl_host`, `highlight_div` / `_span` / `_image` (an image gets wrapped in `span.hl-img-host`); scss `Highlights`; palette vars `--hl-NAME` |
| Highlights in equations | `\hl[name]{STEPS}{colour}{part}` (rounded box), `\hlo[name]{…}` (oval), `\eqmark{name}{part}` (anchor only) | lua `highlight_math` (strips `[name]`, `\eqmark`→`\htmlData`, emits `span.hl-math-slot` fragments); js module 1 patches `katex.render` (macros → `\htmlData`, trust only `\htmlData`) and moves the slots into the parts |
| Annotations (labels + arrows) | `::: {.annot to="n1 n2" pos=below\|above\|left\|right dist= shift= x= y= steps= arrow=fat\|thin\|none box=false color= size= sub="…" gap=}` label `:::`; `to` = equation names or element ids | lua `annotation`; js module 2 (`target`, `layoutOne`: label placement, SVG polygon arrows between box edges; colour from the target's `.hl-fill`) |
| `.matrix` | box with a frame and centred label | scss |
| 3D | `rotate-x/y/z` (PowerPoint order Y, X, Z), `perspective=`, `face=top\|side\|depth` (+ `depth=`, `angle=`), `.tilt-shadow` | lua `tilt`; scss `3D tilt` |
| Offline assets | fonts + KaTeX in the extension | `_extension.yml`, `Pandoc()` dependency |

---

## 4. Invariants and pitfalls (read before editing)

- **Positioning.**
  - With Quarto `.absolute`, `left=`/`top=` attributes are lost as soon as a `style=` attribute is set. `box_attrs` (run first) therefore moves the position attributes of divs into `style`; images keep Quarto's native attributes.
  - Lua code that adds a style must move the position attributes into it first (see `tilt`, `highlight_image`).
  - Authors and the converter write positions as attributes (`left=144 top=184`), never in `style=`.
- **reveal auto-animate.**
  - reveal measures `offsetLeft` (relative to the positioned parent). `talkMatcher` measures relative to the `<section>` and divides by any CSS `zoom`.
  - reveal also pairs `h1-h6, p, li` by their text: section title words are spans, not `<p>`.
  - A matched element gets `transform: none !important` while animating. So a rotation goes on an **inner** element; the outer one carries the `data-id` and the position.
  - Unmatched elements of the old slide vanish at once. Section slides therefore carry ghost copies of the other slide's text (`sec-ghost`) and the header carries a hidden copy of the summary content (`sec-main-copy`). `clean()` strips fragments, audio, `hl` and the data-id of rotated elements from that copy.
- **Performance.** Animate only transforms and opacity. The section block is a fill plus 4 edge bars, animated with transforms only, so there is no re-layout per frame.
- **Fragments.**
  - reveal **renumbers** `data-fragment-index` at init, before KaTeX runs. Anything that must be a fragment has to exist in the HTML at build time; equation highlights are pre-built slots, moved by JS later.
  - The fill of a highlight is the fade-out fragment, and reveal owns its `opacity`. The colour and opacity are therefore painted by `.hl-fill::before`.
- **Highlight layering.** In text boxes the highlight sits under the text and inside the border (`.hl-under`: `isolation: isolate` + `z-index: -1`; note that a negative z-index child is still painted *above* the host's own border, so a fill must never reach the border); on images it covers the image. Gridded highlights (no pad/radius/outline) are wrapped in one `.hl-layer` holding the opacity, cells opaque. Cells are exactly on the pixel grid (never 0.5 px larger: at zoom 1 that painted a half-tone fringe over the lines and the border). Two touching cells shown at the same time would show an antialiasing seam when the slide is scaled by a fraction: the left/upper one is therefore extended 1 px under its neighbour (only when the neighbour is visible whenever it is, and painted after it).
- **Citations.** Citeproc runs after all Lua filters. The filter therefore resolves citations itself (mini-citeproc run, labels in `citation-label`) and sets `suppress-bibliography` when it fills `#refs`. Pandoc sentence-cases titles, hence `text-case="title"` in the CSL.
- **Lists.** The list styling applies to every `ul`/`ol` inside `.reveal .slides`. Lists that must look different (TOC, menus) need their own classes. In `.tb` boxes (converter) sizes and italics come from the text itself, never from the level (`li:not(.tb li)` rules); PowerPoint's `spcBef` is ignored on the first paragraph of a box (selector `:is(ul,ol):not(li *):first-child`).
- **Slide transitions.** reveal animates each slide with its OWN `data-transition`; a slide with `none` vanishes at once while the next one slides in (the "lag" of a lone `transition="slide"`). `push=` therefore marks both slides; a push slide is `visibility: hidden` unless `.present` or `.talk-pushing` (it waits shifted by `--sec-bleed-*`, which the section morphs and auto-animate change: it would drift into view); the off-screen section edge bars of a pushed slide are hidden (`.talk-pushing`), and the push distance includes the section bleed (`--sec-bleed-x/y`).
- **Quarto figures.** Quarto's `.reveal .slide figure>figcaption {font-size: .7em}` beats a plain `.reveal .x figcaption` rule: the caption rules use `.reveal .slide … figure > figcaption`.
- **Grid snapping.** `snap()` must leave a single-cell spec unchanged ("43" would read as 43 equal cells); with a known size the lines are written in whole px (a % rounded to 4 digits landed on x.99 px and blurred a 1 px line over 2 px).
- **Audio "blocked".** `play()` rejects with `AbortError` when the sound is paused before it starts (a stop on the next click, a quick toggle): that is not the browser's autoplay block (`NotAllowedError`), so the icon is not marked `.blocked` then.
- **Font sizes.** 1 pt = `--talk-pt` (1.24 px: 4/3 px × 0.93, Libre Franklin is wider than Franklin Gothic). The root font is 20 pt (24.8 px). `size=` and the `.tb` defaults use the variable, `tools/tidy.py` uses the same factor (`PT`).
- **Slide numbers.** The summary of a full section is `uncounted` too; `.test-slide` / `.additional` are recognised by class, not by `visibility`, so the summary keeps the header's number.
- **Grid boxes.** Lines are placed on whole pixels when the box has `width=`/`height=` (inner size = size − 2 × border), otherwise centred on the boundary in %. Cells and lines are absolutely placed divs inside the box; highlights of the box (`hl-under`, z −1) lie under the cells' text, lines (z 2) above everything. A cell `.fragment` is a normal reveal fragment (the lines are separate elements, so they stay). Colour names: `color_value` resolves theme names (`THEME`), then palette `--hl-NAME`, then CSS names; `theme_color` (attributes) uses it.
- **Shortcodes run after the filters.** `talk.lua` never sees what `{{< audio >}}` produces, so the shortcode adds its icon itself (shared `audio_icon.lua`).
- **Keys.** reveal binds H/J/K/L, G, B, F, O, S, E, `.`. The template uses **A** (audio) and **R** (highlight areas).
- **Measuring.** Non-current slides can be `display: none`, so layout code (annotations, bleed) must run on `ready`, `slidechanged`, `fonts.ready` and after KaTeX renders.
- **Mermaid.** Quarto turns ```` ```{mermaid} ```` into a RawBlock `<pre class="mermaid mermaid-js">` *before* talk.lua runs, and draws it in the browser on `load`, in place, so the slide must be laid out at that moment (CSS `:has(pre.mermaid-js)`). Do not rely on talk.js for this: on some decks it runs after `load`.
- **Hand-written style pitfalls.**
  - `  -` (an empty level-2 item) right under a level-1 item's text is a setext heading underline: write a level-1 `-` there.
  - A `.fade-in-then-out` at click n hides at click n+1, which must exist on the slide (else add `[]{.fragment fragment-index=n+1}`).
  - A span box has no `<p>`: its line height is set to reveal's 1.3 explicitly; a heading has 1.07, so a text-box title moved to `## Title {top=}` is placed 6 px lower than the box was.
  - Old converted boxes were flex columns: overflowing content shrank empty-line gaps. Lists are not flex items, so a long run of empty lines can need one line less.
- **KaTeX.** `\htmlData` values cannot contain `#` or commas, so equation colours are palette names. Wrap a relation or operator inside a macro in `\mathrel{}` / `\mathbin{}`, or it loses its spacing.

---

## 5. Tools (`tools/` of the repository, PowerPoint → this template)

Run `_extensions/tools/build_deck.sh talk.pptx` from a deck folder (new talks only: the PhD deck is now hand-edited). `sections.py` (lists of section slides), `deck_patches.py` (hand rewrites) and `_header.yml` (the YAML header) are still the PhD deck's own: adapt them for another talk (making them per-deck configuration is in section 6). Order: pptx2qmd → sections → cites → highlights → deck_patches → segments → captions → tidy → simplify → `_header.yml` + render. It rebuilds `index.qmd` byte for byte. Environment of `pptx2qmd.py`: `TEST=1` (slides marked `.test-slide`), `BACKUP_FROM=67` (appendix marker before that slide), `SKIP=…` (dropped slides).

- `pptx2qmd.py` (+ `omml.py` for Office Math → LaTeX) converts each pptx slide into absolute-positioned divs and images, with fragments, Morph pairs (`data-id`), audio, and 3D from `scene3d` (rotate-z = rev − rot + 180).
  - Lists: Markdown lists; animated paragraphs → `[text]{.fragment data-fragment-index=k}` inside the item (indices are shared with the other objects of the slide, so native `.incremental` is not used). Per-level `marL`/`indent`/`spcBef`/`spcAft` that differ from the template defaults → `--talk-*` variables on the box; non-default markers → `.b-*N` classes; `cap="all"` → `.caps`.
  - `omml.py`: spaces typed in an equation (also no-break spaces) → `\ `; a capital in a "…Script…" font with `m:nor` → `\mathscr{}`.
- `sections.py`: rewrites the section and side-panel slides (lists in the file).
- `cites.py`: turns footer reference boxes and `[Label]` text into `[@key]`, keeping the font size of split runs.
- `highlights.py`: turns red half-transparent overlay shapes into `hl` on the object underneath, with grid snapping or % rectangles.
- `deck_patches.py`: per-slide hand rewrites (replace / drop by data-id / add attrs / append).
- `segments.py`: boxes drawn side by side → grid boxes. (1) rows of ≥3 touching framed boxes (same border, top/height within 4 px; chains ignore overlapping boxes) → one box `cols=… lines=true` + a list (`cols=N` when the cells are equal within 2 px; no list when every cell is empty); shared click → on the box; left/right snapped to the other rows; a morphing box keeps its `data-id` on its cell, `hl*` too. (2) rows of coloured boxes without border (overlays) → one box `cols=… hl="CLICK-@k NAME"`, colours named from `_header.yml` (talk: highlight: colors) then the template palette (`colour_name`). (3) vertical stacks of ≥3 equal empty framed rows → `rows=N lines=true`, row highlights → `STEPS@row`. Skips rotated boxes and drawn shapes. Counts data-ids quoted or not (tidy.py too).
- `deck_patches.py` op `colour-names`: text boxes with a palette background → `hl="0- NAME" hl-radius=…` (slide 8: the section labels share the overlay's colour names).
- `captions.py`: a picture (≥ 60 px, no style/hl/morph) + a one-line text box (no frame, colour or click) within −10…30 px above/below it and aligned (left edges or centres) → one `.caption-top`/`.caption-bottom` figure whose box is the picture's.
- `pptx2qmd.py` also: an effect's start delay inside its click → `delay=S` (`delay=end` when that click plays a sound: PowerPoint's delay is then the sound's length); a paragraph shown at click a and hidden at click b > a+1 → two nested spans (`.fade-in-then-out` only when b = a+1), nothing of its own when it appears with its box; a capital in a "…Script…" font in plain text → `$\mathscr{X}$`; PowerPoint push → `push=DIR`; the title layout → `## {.title-slide}` (its shapes dropped, filled from `_header.yml`), later ones `parts="title logos"`.
- `tidy.py` (last): rewrites every attribute block into the short form (positions as attributes, `size=` in pt, theme colour names, `.body`/`.ttl` defaults dropped, `.nowrap`) and drops `data-id`s used only once, and flattens a `.grp` that holds a single object; `keep_under`: a picture fading out while another fades in at the same place and click stays (no fade-out), to avoid the dark flash of two half-transparent pictures. The earlier tools still read and write the long `style=` form.
- `simplify.py` (after `tidy.py`, objective 2): rewrites a converted deck into the hand-editable style: SVG lines → quarto-arrows shortcodes, nested fade wrappers → one `.fade-in-then-out` object, click groups, one-line spans, `.box` / `.filled`, `shape=` from SVG geometry (quarter turns become directions), titles → `## Title {top=}`, PowerPoint gaps → empty lines, diagonal overlays → `hl="@diag …"`, `.move` wrappers merged, `play=`, flipped pictures saved as `_flipped` files. Prints what it left untouched.
- `shoot_steps.js`: headless screenshots of every slide / click step of a rendered deck (for the EXPECT checks and pptx comparisons). Note: `Reveal.getSlides()` skips uncounted slides; the script walks `section:not(.stack)` instead.
- `REMAINING_DIFFERENCES.md` / `SUBSTANTIAL_FIXES.md` (project root): current pptx ↔ Quarto differences of the PhD deck.

---

## 6. Ideas, not implemented (candidates)

- An automatic test runner for `template.qmd`: render it, screenshot every fragment step headless (`tools/shoot_steps.js` does this part), pixel-diff against stored references, and report the failing slides by their EXPECT comment.
- Annotations:
  - curved arrows;
  - automatic placement that avoids overlaps;
  - an `anchor=` side for the arrow start;
  - annotating parts of images by area (`to="img@(x,y,w,h)"`).
- Coloured overlays drawn on top of autosimilarity matrices (not in a row): convert them to `hl=` areas with palette names, like the row overlays of `segments.py`.
- Converter:
  - detect section slides automatically instead of the hard-coded lists in `sections.py`;
  - detect equation ellipses and labels → `\hlo` + `.annot`.
- Clean PDF export (`?print-pdf`): every annotation laid out, highlights shown at their final state.
- Morph of equation parts between slides (data-id on `\eqmark` parts).
- A dark theme variant through `talk: colors:`.
- Table of contents: final design (Axel will specify); maybe a "current section" highlight and automatic outline slides before each section.
- Section style switch during the talk (key), if ever needed.
- Converter: single-line text boxes that wrap because Libre Franklin / KaTeX are wider than the pptx fonts (see `REMAINING_DIFFERENCES.md`).
- Converter: move the deck-specific parts of `tools/` (`sections.py` lists, `deck_patches.py`, `_header.yml`) into a per-deck configuration folder, so that the repository holds only generic code.
- Converter: `build_deck.sh` should write `_extensions/tour`-style media paths and the deck `_quarto.yml` (listing the tour) for a new deck.
