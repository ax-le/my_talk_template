# TL;DR: Yet another Claude written template for presentations

Hi!

During my PhD, I developed a PowerPoint "template" (slides to be copy-pasted, rather than a real template) that I really liked, and that I still want to use. The main assets came from the 'morph' transition in PowerPoint. I think this makes it very easy to grasp an otherwise complex notion when going from matrices to tensors. It also makes pretty slides!

But that included a physical dependence on PowerPoint and Windows, which started to become more of a problem with time (versioning is complicated, I need to keep a Windows laptop for presentations while I would prefer using a Linux distribution, most of the time it's shared in PDF so most of the stuff is lost in translation, etc.). So, I was kind of trapped with PowerPoint, the alternative being redeveloping my own template in an HTML-compatible format (and devoting a LOT of time to this matter).

**But here come LLMs!**

Thanks to Claude, it actually became possible to develop a template that is HTML readable, easy to maintain, version, share, and deploy, that works on Linux, and remains relatively easy to write, without spending an awful amount of time developing the template (~~let's spend energy and an awful amount of tokens instead!~~).

So here it is, my very personalized Quarto template to make morphing possible between slides and objects, thus keeping my super awesome PowerPoint template while freeing myself from PowerPoint! It's very much developed for my taste, and written in that sense, but having spent the tokens on it, why not open-source it?

Feel free to use it, but note that it's not developed to be the very best template for everyone, but rather to transfer what I was doing in PowerPoint to another framework. So you might ask me to add features, but it would probably be faster to make your own template with Claude or to fork and specialize it! Nonetheless, I'm open to suggestions, and would love to extend the template :)

The remainder of the README is a technical part written by Claude directly, so I leave you with the machine. Have a nice day!

---

# talk: a Quarto reveal.js template

The template serves two goals, one after the other: first, **rebuild a PowerPoint talk in Quarto** so that it looks and clicks the same; then, **keep the deck short and easy to edit by hand**, with every repeated pattern turned into a template feature. New talks are written directly in this second style.

This is the look of the PhD-defense deck as a reusable format: a 1280 × 720 canvas, the "Rognage" colours, Libre Franklin, and the dark bar on the left. On top of it:

- section slides with a Morph-like transition;
- side-panel slides;
- audio, on click or automatic;
- citations from `.bib` files, with labels like `[MCB22a]`;
- highlights of whole objects or of their parts (cells, rows, areas of an image), shown on clicks;
- 3D-tilted images;
- configurable colours;
- PowerPoint-like lists (markers and indents of each level, clicks per item or per level-1 item);
- grid boxes: one box cut into cells (matrices, structure bars, overlays), with lines, texts, clicks and colours;
- a test slide, and an appendix marker after which every slide is numbered "additional-N";
- short attributes (`left= top= size=18 color=accent`…) instead of `style=`, with PowerPoint-like defaults;
- a basic table of contents built from the sections.

## Installing the template (read this first)

**This repository is not a Quarto project and does not render on its own**: running `quarto render` or `quarto preview` inside it gives `… is not a project` / `Unable to read the extension 'talk'`. Quarto only finds a format in the `_extensions/` folder of the document being rendered (or of its project), so this repository is laid out to **be that `_extensions/` folder**: its root holds the format (`talk/`), the arrows extension it uses (`arrows/`), the PowerPoint converter (`tools/`) and the feature tour / test deck (`tour/template.qmd`).

A **deck** is any folder with your `.qmd`, your `media/`, your `.bib`, and this repository cloned as `_extensions`. Three steps, from scratch:

```bash
mkdir my-talk && cd my-talk
git clone git@github.com:ax-le/my_talk_template.git _extensions   # 1. the template, as the deck's _extensions/
echo "_extensions/" >> .gitignore                                   # 2. the clone is not part of the deck's own repo
cp _extensions/tour/template.qmd talk.qmd                           # 3. a starting point (or an empty file with
quarto preview talk.qmd                                             #    "format: talk-revealjs" in its YAML)
```

Because `_extensions/` is a clone, a template change made from inside any deck is a normal `git commit` + `git push` *in `_extensions/`*, and the other decks get it with `git -C _extensions pull`. If you already have the clone elsewhere on your machine, `git clone /path/to/my_talk_template _extensions` works too (then `git -C _extensions remote set-url origin git@github.com:ax-le/my_talk_template.git`).

Two alternatives, if you do not want a clone per deck:

- `quarto add ax-le/my_talk_template` copies `talk/` and `arrows/` into your deck's `_extensions/` (no git link: run `quarto update` to get newer versions).
- a directory junction / symlink named `_extensions` pointing at your clone (`mklink /J _extensions C:\path\to\my_talk_template` on Windows, `ln -s` elsewhere) — fine locally, invisible to git.

### Previewing or testing the template itself

The tour (`tour/template.qmd`: every feature, one slide each; its `EXPECT:` comments say what each slide must do) is also rendered **from a deck**, never from this repository. Quarto treats a file under `_extensions/` as outside the project unless the deck's `_quarto.yml` lists it, so a deck meant for the template itself contains nothing but that file:

```yaml
# _quarto.yml of the "template" deck (all_the_pres/template in Axel's set-up)
project:
  type: default
  render:
    - _extensions/tour/template.qmd
```

```bash
git clone git@github.com:ax-le/my_talk_template.git _extensions
quarto preview _extensions/tour/template.qmd      # or: quarto render
```

A plain `quarto preview` in that folder opens the project root, where there is no page (the only output is `_extensions/tour/template.html`), hence a "Not Found": either give the file name as above, or keep a one-line `index.html` at the root that redirects to `_extensions/tour/template.html` (the `template` deck does).

Any real deck can list `_extensions/tour/template.qmd` next to its own `.qmd` in the same way, to check the template after a change. Notes for AI agents: `AGENTS.md`.

```yaml
format: talk-revealjs
```

Ordinary Markdown slides work as usual. Text starts under the title, at 180 px, at the left edge of the title (144 px) and runs to 60 px from the right edge of the slide, like a box with `right=60` (change these with `--talk-content-top`, `--talk-content-left`, `--talk-content-right`), at 20 pt, with the bullets of the PowerPoint master (see Lists). **Write the content first, position only what is special.**

## Placing and sizing things: short attributes

No `style=` is needed. On any div or span:

```markdown
::: {.absolute top=40 right=60 width=330 size=16 color=accent align=right}
A note in the upper right
:::

::: {.absolute .tb left=144 top=470 width=560 border="2px solid accent" align=center}
A PowerPoint-like text box
:::

Some [smaller words]{size=14} and [coloured ones]{color=accent}.
```

| attribute | meaning |
|---|---|
| `left top right bottom width height` | position and size in px on a 1280 × 720 slide (Quarto's own attributes on `.absolute`; `%` also works) |
| `size=18` | font size in points, as in PowerPoint (× `--talk-pt` = 1.24 px, Libre Franklin being wider) |
| `color=` `background=` | any CSS colour, or a theme name: `text`, `title`, `accent`, `background`, `bar` |
| `align=center` / `right` | text alignment |
| `border="1px solid accent"`, `radius=10`, `line-height=1.2`, `padding=` | frame, rounded corners, spacing |

Boxes converted from PowerPoint keep its defaults, so they only state what differs:

| class | default |
|---|---|
| `.tb` | text box: 18 pt, black, inner margin 0.05" × 0.1" |
| `.tb.body` | content placeholder: 20 pt, theme text colour, line spacing 94 % |
| `.tb.ttl` | title placeholder: 44 pt, title colour, line spacing 89 % |
| `.nowrap` | no line wrapping |

`style=` still works for anything else (rotations, CSS variables…); the filter merges it with the attributes.

## Colours

```yaml
talk:
  colors:
    background: "#EBE7DD"   # slide background
    text: "#1A2E40"
    title: "#1A2E40"
    bar: "#1A2E40"          # vertical bar on the left
    accent: "#69A1AB"       # default colour of section blocks and panels
```

**Slide transitions.** PowerPoint's "Push" is `## Title {push=up}` (also `down`, `left`, `right`): the previous slide and this one move together, as one strip, in 0.8 s (YAML `talk: push-duration: 0.6s`); going back plays it in reverse. Quarto's own `transition="fade"`, `"convex"`, `"zoom"`… still work, but reveal.js animates only the slide that carries the transition, so `transition="slide"` alone makes the old slide vanish at once and the new one slide in over an empty background: use `push=` for a push. Morph-like animations have their own `auto-animate-duration`.

For a single slide, Quarto's own attribute still works: `## Title {background-color="#FFF"}` (also `background-image=`, `background-gradient=`…).

## Title slide

```yaml
title: "Unsupervised<br>Machine Learning Paradigms"
author: "Axel Marmoret"
institute: "IRISA"
subtitle: "PhD defense"
date: 2022-12-02
date-format: long               # → December 2, 2022
talk:
  title-slide:
    note: "*Under the supervision of*<br>*F. Bimbot and J. E. Cohen*"   # optional extra line
    logos: [media/irisa.png, media/rennes.png]                         # bottom left, side by side
    # background: "#69A1AB"     # default: the accent colour;  date: "…" overrides the date text
```

```markdown
## Test {.test-slide}

## {.title-slide}                                  ← the title slide, filled from the YAML

…

## Thank you! {.title-slide parts="title logos"}   ← e.g. the closing slide
```

- Without any `{.title-slide}`, one is added after the leading test slides; `talk: title-slide: false` gives Quarto's own title slide back.
- Look: accent background, two frame corners (top left, bottom right), title in capitals, then "author, institute, subtitle", the note, the date, the logos bottom left; no left bar.
- `parts="…"` picks among `title byline note date logos`; a heading text replaces the YAML title.
- Every size and colour is a CSS variable on `section.title-slide` (`--ts-frame`, `--ts-frame-w`, `--ts-title-size`, `--ts-byline-color`…), to restyle it for another talk.

## Captioned pictures

A photo with its name (or any picture with a one-line legend) is **one native figure**: the caption is the image's alt text.

```markdown
::: {.absolute .caption-top left=34 top=398 size=18}
![Frédéric Bimbot](media/bimbot.jpg){width=164 height=230}
:::
```

- `.caption-top` puts the caption above the picture, `.caption-bottom` below. The box only gives the place (`left= top=`; no `width=` needed): it shrinks to the picture, whatever `width=`/`height=` the picture has, and the caption hangs just outside the picture, centred on it, so the picture never moves whatever the caption's length or size.
- The caption takes the box's font (`size=`, `color=`, italics with `*…*` in the caption), not Quarto's small grey caption.
- From PowerPoint, `_extensions/tools/captions.py` joins a picture and a one-line text box just above (or below) it and aligned with it.

## Clicks

Native reveal.js fragments: `.fragment` + `fragment-index=N` (the click number), `.fade-out`, `.fade-in-then-out`… Two more things:

- **Delay** (PowerPoint "after previous" + delay): `delay=3.9` on a fragment makes it appear 3.9 s after its click, by itself. Going back hides it at once.
- **After the sound**: `delay=end` makes it appear when the sound playing at its click ends, whatever its length (e.g. the spectrograms once the sound started by the same click has played; replace the file and nothing else changes). Stopping the sound (click on the icon, key **A**) shows it at once, and so does a click with no sound playing or a sound blocked by the browser.
- **Appears at one click, disappears at a later one**: two nested spans, `[[text]{.fragment .fade-out data-fragment-index=3}]{.fragment data-fragment-index=1}` (`.fade-in-then-out` only means "gone at the very next click").

## Lists

Markdown lists have the indents and spacing of the PowerPoint master, and a different marker for each level:

| level | marker | text | text starts at | space before |
|---|---|---|---|---|
| 1 | ■ | normal | 0.42" (40 px) | 10 pt |
| 2 | – | italic | 1" | 5 pt |
| 3 | • | normal, smaller (18 pt) | 1.5" | 5 pt |
| 4 | ○ | italic | 2" | 5 pt |
| 5 | ► | normal | 2.5" | 5 pt |

Deeper levels start again with the markers of levels 1–5 (and keep moving right by 0.5"). Decks converted from PowerPoint take these markers too when their master used its own default ones (■ – ■ –); other markers of the pptx are kept.

- **All at once** is the default. **One click per item**: Quarto's native `::: {.incremental}` (or `## Title {.incremental}`, or `incremental: true` in YAML); every item, sub-items included, is a click, and its marker appears with it. `::: {.nonincremental}` switches it off again.
- **One click per level-1 item** (PowerPoint "by 1st level paragraphs"): `::: {.incremental levels=1}` (also on a heading). Sub-items appear with their parent. `levels=2` makes levels 1 and 2 clicks.
- **Pauses** `. . .` and `[text]{.fragment}` inside an item also work: the marker waits for the text.
- **Other markers.** Per box or slide, with a class: `.b-sq`, `.b-dash`, `.b-dot`, `.b-circ`, `.b-tri`, `.b-check`, `.b-arrow`, `.b-none` (all levels), or `.b-dot0` … `.b-dot4` (one level; 0 = level 1). Or per level with an attribute: `::: {bullets="• – ✓ none"}`. For the whole deck: YAML `talk: bullets: "■ – • ○ ►"`. `.no-bullets` removes markers and hanging indents.
- **Spacing.** `spacing="20 10"` on a box or slide: space before level-1 items / before deeper items, in pt (one value: every level; default 10 and 5). `line-height=1.5` sets the line spacing; `-` alone is an empty line (see Titles, empty lines).
- **Fine control.** Everything is a CSS variable that any element can set (the converter writes them from the pptx when a text box differs from the master): `--talk-bN` (marker), `--talk-bN-size` (factor), `--talk-marN` (left edge of the text), `--talk-indN` (marker position relative to the text, negative = hanging), `--talk-spcbN` (space before), `--talk-spca` (space after), `--talk-szN` / `--talk-stN` (size / style of Markdown items), `--talk-bullet-color`, `--talk-bullet-font`.
- Numbered lists (`1.`) use the same indents, with "1." markers.

## Columns

Native Quarto columns, laid out as a flex row with a gap (Quarto alone puts them side by side with no space):

```markdown
:::: {.columns gap=60}
::: {.column width="40%"}
…
:::
::: {.column width="60%"}
…
:::
::::
```

`gap=` is in px (default 40); columns without `width=` share the space equally. Any content goes inside (lists, pictures, boxes, maths).

## Grid boxes: one box divided into cells

Matrices, structure bars, tensors seen from the front, colour overlays on an image… are all the same thing: **one box, cut into cells**, whose cells can have a text, appear, or be coloured at given clicks. One syntax covers them all:

```markdown
::: {.absolute left=360 top=270 width=790 height=45 border="1px solid text" cols="2 2 1 1 2" lines=true hl="2-@3 accent"}
- a
- b
- d
- [e]{.cell .fragment}
- [f]{.fragment}
:::

::: {.absolute .matrix left=150 top=420 width=150 height=120 cols=3 rows=3 lines=true hl="1@2,2; 2-@*,3 teal"}
$M$
:::
```

| attribute | meaning |
|---|---|
| `cols=5`, `rows=3` | number of equal columns / rows (default 1) |
| `cols="2 2 1 1"` | relative widths (here the last two cells are half as wide); same for `rows=` |
| `lines=true` | lines between the cells, with the box's border width and colour; or `lines="2px accent"` |
| `hl="STEPS@CELL COLOUR; …"` | cells coloured at clicks (see Highlights): `3` (3rd cell, row by row), `2-4`, `2,3` (column 2, row 3), `*,3` (whole row 3) |
| a list | one item per cell, row by row: the text of the cells (optional: a matrix keeps its single label) |
| `[x]{.cell …}` alone in an item | attributes of the whole cell: `.fragment` (the cell appears), `background=`, `hl=`, `data-id=` (the cell morphs on its own into the element with the same `data-id` on the next slide, e.g. the slices of a tensor) |

- **Lines** are drawn above the colours and never double the box's border; a cell that appears on a click leaves the lines in place. When the box has a `width=`/`height=`, the cell boundaries are rounded to whole pixels inside the border, so lines, cells and highlights fall exactly on each other.
- **Colours** can be names: the theme's (`text`, `title`, `accent`, `background`, `bar`), the highlight palette (`red`, `teal`, `gold`, …), or your own names defined once in YAML, e.g. for song sections: `talk: highlight: colors: {intro: "#F2C418", verse1: "#4A845E", …}`, then `hl="1-@3 intro"` and `hl="0- intro"` on the matching label: both use the same colour and transparency.
- **An ordinary span stays text**: `[f]{.fragment}` makes only the text appear.
- **From PowerPoint** (`_extensions/tools/segments.py`): a row of touching framed boxes becomes one box with `cols=` and `lines=true` (aligned on the other rows of the slide; a box that morphs keeps its `data-id` on its cell); a row of coloured boxes without border (an overlay on an image) becomes one box with `cols=` and `hl=` (colours named from the deck's palette, clicks kept); a vertical stack of equal empty rows becomes one box with `rows=N lines=true`, the rows' highlights turned into `STEPS@row`.

## Test slide and appendix (backup slides)

```markdown
## Test {.test-slide}       ← clicker / sound check before the talk: counter "test slide"

## Conclusion

- …

::: {.appendix}
:::
                            ← like LaTeX \appendix: EVERY slide below is numbered
## Extra results               additional-1, additional-2, … (references slide included)
```

- **The marker** is an empty `::: {.appendix}` div. Put it once, at the end of the last counted slide (usually the conclusion). It is explicit in the source and the render log repeats it: `talk: appendix after the slide "Conclusion": the 17 following slides are numbered additional-1 … additional-17`.
- **Exceptions.** A slide after the marker can stay counted with `{.counted}`; a single slide before it can be made additional with `{.additional}`. The summary of a section pair shows its header's label.
- **Count.** Test and additional slides are left out of the total (the slide after the test slide is 1).
- **Labels.** `talk: slide-number: {test: "test", additional: "backup {n}"}` (`{n}` = rank). A slide with only `visibility="uncounted"` keeps reveal's native behaviour (the previous number).

## Table of contents

```markdown
## Outline {.toc-slide}
```

The filter fills this slide with one entry per section (every `.section-header`, add `.no-toc` to skip one): the section title, a link to it, and its summary (the panel text of the `.section-summary`, or else the header subtitle). To place the list yourself inside any slide, write an empty `::: {#toc}` `:::` div. The look is basic on purpose: style it through `.talk-toc`, `.toc-item` (numbered by a CSS counter, `data-toc-index`), `.toc-title` and `.toc-summary`.

## Section slides

(A full section header shows no slide number; its summary does.)

```markdown
## Convolutive Block-Matching (CBM) algorithm {.section-header}

Optional subtitle [@marmoret2022cbm]

## CBM algorithm {.section-summary}

::: {.section-panel}
Optional text under the title, in the panel
:::

Slide content (placed right of the panel)
```

- **Header slide.** The block covers the whole screen, framed by a border at the screen edges.
- **Summary slide.** Only the right border remains, closing the panel. It moves with the panel.
- **Title words.** Every word glides from its place in the header to its place in the panel. Words that exist in only one title fade where they are: here "Convolutive Block-Matching ( )" fades in place while "CBM algorithm" moves.
- **Same in both directions.** The animation starts from exactly what is on screen and runs backwards (summary → header) the same way.
- **Uncovering the content.** The summary content sits under the block, so the shrinking panel uncovers it, and going back the growing block covers it.
- **References.** Citations in the title or subtitle are listed at the bottom: across the header, then in the panel. An explicit `::: {.section-ref}` replaces this automatic list.
- **Any screen ratio.** On 4:3 or 21:9 screens the colour still reaches the screen edges.
- **One slide number.** The summary keeps the header's slide number (it is `visibility="uncounted"`). Add `visibility=` yourself on the summary to change this.
- **Smoothness.** The block is a fill plus four border bars, animated only with GPU transforms (no re-layout per frame). On a slow machine, a longer `duration` (e.g. `duration=1.6` on the header) also helps.

### Section style: full or simple

The header → summary pair above is the **full** style. The **simple** style keeps only the header slide, with the title alone (no subtitle, no reference line, no morph): write the header alone. (A `.section-summary` written after a simple header is kept as an ordinary slide with its content, panel dropped, and left out if it has no content.)

- for one section: `## CBM algorithm {.section-header section-style=simple}` (or `section-style=full`);
- for the whole deck: YAML `talk: section: style: simple`.

The table of contents uses the summary text in both styles.

### Side panel without transition

```markdown
## PhD,<br>in a nutshell {.side-panel}
```

This gives the same left panel as a summary. Content positioned on the panel (photos…) stays visible above it.

### Options

Set the defaults in YAML under `talk: section:`, or override them on one slide as attributes of the heading. A summary inherits the options of its header.

| option | default | |
|---|---|---|
| `color` | accent | block / panel colour |
| `text-color` | title colour | |
| `border-width`, `border-color` | `21px`, `#000` | frame of the header, line closing the panel (`0` to remove) |
| `panel-width` | `440px` | the summary title and the panel subtitle grow with it (sizes below are for 440 px) unless given explicitly |
| `title-size`, `summary-title-size` | `60px`, `50px` | write them in px (the summary title is the header title zoomed by their ratio) |
| `subtitle-size`, `panel-subtitle-size`, `ref-size` | `24px`, `24px`, `12px` | subtitle of the header; of the panel (defaults to `subtitle-size`, scaled by the panel width); references |
| `title-width`, `title-weight` | `900px`, `700` | centred title in the header |
| `panel-padding`, `panel-top` | `36px`, `96px` | margin on both sides of the panel text (centred in the panel, its closing line excluded); top of the title |
| `duration`, `easing` | `1.2`, `ease-in-out` | |
| `style` (YAML) / `section-style` (heading) | `full` | `full` or `simple` (see above) |

## Citations

```yaml
bibliography: refs.bib
talk:
  citations:
    slide-refs: true             # list each slide's references at its bottom
    highlight-author: Marmoret   # name in bold in the lists, own labels in bold everywhere
```

| Markdown | result |
|---|---|
| `[@kim2007nonnegative]`, `[@a; @b]` | `[KC07]`, `[KC07, Mar+20]` |
| `[@foote2000automatic]{.fullcite}` | the full reference in the text, like `\fullcite` |
| `[[@grill2015music]]{.refs-only}` | in the slide's reference list but not in the text (e.g. a work only shown in a chart) |
| `## References {.references-slide}` + `::: {#refs}`/`:::` | the complete bibliography, two columns |
| `{.no-slide-refs}` on a heading | no reference list on that slide |

- **Labels.** They follow biblatex `alphabetic`: `Foo00`, `MCB22a`, `Mar+20`. A `shorthand = {…}` field in the `.bib` always wins, so a thesis `.bib` gives the same labels as the LaTeX document.
- **Own work.** With `highlight-author`, labels of entries by that author (`**[MCB22a]**`) are bold in the text and in the lists.
- **Formatting.** References use `alphabetic.csl`. Set `csl: other.csl` for another style, for example author-year.

## Audio

```markdown
{{< audio media/intro.mp3 >}}                              click to play / stop
{{< audio media/intro.mp3 autoplay=true delay=0.5 >}}      plays when the slide opens
{{< audio media/x.mp3 fragment=true autoplay=true >}}      appears on a click, and plays then
{{< audio media/x.mp3 id=v1 label="Verse 1" loop=true volume=0.6 left=300 top=500 size=40 >}}
```

The speaker icon is drawn by the template (it glows yellow while playing, red when the browser blocks the sound). It is large enough to click (2 em, about 50 px in body text, with a margin around it that also reacts to clicks) and does not push the lines of a list apart. Change its size with `size=` on one icon (px or any CSS length), or for the whole deck with YAML `talk: audio: size: 60px`.

The same icon without the shortcode, e.g. at an exact place: `[]{.absolute .audio-btn left=198 top=178 data-audio="media/x.mp3"}` (an empty span with `.audio-btn` gets the icon). This is what the converter writes for PowerPoint sound objects.

Any element can be a sound button with these attributes (an image keeps its own picture and, like the icon, gets a pointer cursor, a slight zoom on hover and the yellow glow while playing):

| attribute | effect |
|---|---|
| `data-audio="file.mp3"` | makes the element a play/stop button |
| `data-autoplay=true` / `false` | plays when it becomes visible: when its slide opens, or when its fragment appears |
| `data-autoplay-delay=1` | waits this many seconds before playing |
| `data-loop`, `data-volume=0.5` | loop, volume |

A sound can also be started on a given click: `play=2` on the icon (the icon is there from the start, the sound plays at click 2), or `[]{.fragment data-play="v1"}` plays the element with `id="v1"`. Something that should appear once that sound has ended takes `delay=end` (see Clicks). `[]{.fragment data-stop-audio=true}` stops every sound on that click.

YAML defaults: `talk: audio: { autoplay: false, delay: 0, stop-on-slide-change: true, size: 2em }`.

During the talk, press **A** to stop every sound. Browsers refuse sound before the first key or click; a blocked sound turns its icon red.

## Highlights

The highlight is part of the object, not a second shape laid over it: move or resize the object and its highlight follows (Morph included). In a box with text, the red sits under the text and inside the border; on an image it covers the image. In a grid box or a picture of known size the coloured cells sit exactly on the pixels of the grid lines (nothing bleeds over a line or the border), and two touching coloured cells never show a light seam between them, at any zoom.

```markdown
::: {.absolute .matrix left=300 top=170 width=200 height=30 cols=4 hl="1@1; 2@2; 3@3; 4-@4"}
:::
![](drums.png){.absolute left=144 top=281 width=270 height=117 hl="2@(37.8,30,6.3,19); 3-@(50.7,30,7,19)"}
::: {.absolute .shp left=200 top=400 width=370 height=114 border="1px solid black" rows=6 lines=true hl="1@1; 2@6"}
:::
```

`hl` is a list of `STEPS@AREA` separated by `;`. It works on any div, span or image.

| STEPS | highlighted… |
|---|---|
| `2` | at click 2 only (gone at click 3) |
| `2-4` | from click 2 to click 4 |
| `2-` | from click 2 to the end of the slide |
| `0`, `0-2` | already when the slide opens |

| AREA | part of the object |
|---|---|
| nothing | the whole object |
| `3`, `2-3` | cells of the box's grid `cols=` / `rows=` (see Grid boxes), numbered along the only axis of a 1-row/1-column grid, else row by row |
| `2,3` / `*,3` / `1-2,3` | column, row of the grid (`*` = all) |
| `(x,y,w,h)` | a rectangle in % of the object, e.g. `(37.8,30,6.3,19)`; `px` values also work |

**Grid.** The cells come from the box's `cols=` / `rows=` (equal or relative sizes), the same grid that `lines=true` draws: see Grid boxes.

- **Steps.** They are the slide's click numbers (`data-fragment-index`), shared with the other fragments of the slide.
- **Colour.** Add a colour at the end of an entry: `hl="2 teal; 3-@2 purple"`. It can be a palette name or any CSS colour.
  - Palette: `red` (default), `teal`, `gold`, `orange`, `purple`, `green`, `brown`, `navy`, `black`. Add or change names in YAML (`talk: highlight: colors: { intro: "#F2C418" }`) to give colours a meaning once for the whole talk.
  - `hl-color=…` sets the colour of a whole object; `talk: highlight: { color: …, opacity: 0.5 }` sets the default.
- **Shape.**
  - `hl-shape=round` (with `hl-radius=14`) or `hl-shape=ellipse` gives rounded corners or an oval.
  - `hl-pad=12` makes the highlight stick out of the object like a halo.
  - `hl-opacity=0.7` changes the transparency.
  - `hl-style=outline` draws a frame instead of a fill.
- **Equations.** In LaTeX the [annotate-equations](https://ctan.org/pkg/annotate-equations) package does this with TikZ. Here you mark the part of the equation inside the maths:

  ```markdown
  $$X_{(2)} \approx \hlo{2-}{teal}{Q}\,\hl{3-}{purple}{\text{G}_{(2)}(W\otimes H)^T}$$
  ```

  - `\hlo{STEPS}{colour}{part}` draws an oval and `\hl{…}{…}{…}` a rounded box. They take the same steps as `hl=`, and palette names for the colour.
  - The highlight takes the exact size of that part of the equation, so changing the equation or its font size needs no re-alignment. Wrap a relation in `\mathrel{…}` (e.g. `\mathrel{\hlo{3}{orange}{\approx}}`) to keep its spacing.
  - It relies on KaTeX's `\htmlData`, which the template enables only for this command.
- **Annotations** (labels with arrows, like `annotate-equations`). Name a part of an equation, then attach a label to it:

  ```markdown
  $$\mathrel{\eqmark{iff}{\Longleftrightarrow}} \hlo[x2]{2-}{teal}{X_{(2)}} \mathrel{\hlo[approx]{3-}{orange}{\approx}} \dots$$

  ::: {.annot to=x2 pos=below dist=58 steps=2- sub="(“unfolding” of the tensor)"}
  Barwise TF matrix
  :::
  ```

  - **Naming.** `\hl[name]{…}` / `\hlo[name]{…}` name a highlighted part. `\eqmark{name}{part}` names a part without highlighting it; wrap it in `\mathrel`/`\mathbin` when it is a relation or an operator. `to=` can also be the `#id` of any element (a box, an image).
  - **Placement.** The label is placed `pos=below|above|left|right` of its targets, at `dist` px, moved by `shift` px. `x=… y=…` place it at fixed slide coordinates instead.
  - **Arrows.** One arrow is drawn to each target (`to="q gwh"` gives two). They always point at where the parts are, so editing the equation needs no re-alignment. `arrow=fat` (default, translucent like the PowerPoint ones), `thin` or `none`.
  - **Look.** The colour comes from the target's highlight; set `color=` to override it. `box=false` removes the frame. `size=` sets the font size, and `sub="…"` adds a smaller line under the label.
  - **Steps.** `steps=` works as for `hl=`.
- **Press R** (while preparing a talk) to show every highlight area with its steps, and the grids in blue.
- **`.matrix`.** A ready-made class for a matrix box: a black frame with its label centred.
- **From PowerPoint.** `_extensions/tools/highlights.py` turns half-transparent red overlay shapes into `hl` on the shape or image under them. It snaps them to a grid when they fit one; other overlays become rectangles in %. Overlays it cannot guess (ellipses over an equation, halos) were rewritten by hand in `_extensions/tools/deck_patches.py`.

## 3D images (any image or block)

```markdown
![](q.png){.absolute left=754 top=174 width=233 height=93 rotate-x=-35 rotate-y=-51.5 rotate-z=88}
![](q.png){face=top}      ![](q.png){face=side}      ![](q.png){face=depth depth=0.5 angle=45}
```

- **`rotate-x/y/z`.** A real CSS 3D rotation, applied in the order Y, X, Z like PowerPoint's 3-D rotation. Positioned rotated elements keep their rotation through Morph transitions. Add `perspective=900` for a perspective effect. The converter writes these from PowerPoint's 3-D settings.
- **`face=…`.** Gives the oblique "cube face" look used in the tensor drawings: `top`, `side` (right face), or `depth` (the image lies along the depth axis). `depth` sets the foreshortening and `angle` the direction of the depth axis.

## Arrows, lines and diagrams

No hand-drawn SVG: arrows and lines come from the [quarto-arrows](https://emilhvitfeldt.github.io/quarto-arrows) extension (`_extensions/arrows`), diagrams from Quarto's built-in Mermaid.

```markdown
{{< arrow from="170,595" to="345,595" width=1 size=6 position="absolute" >}}           ← thin arrow (slide px)
{{< arrow from="244,388" to="718,388" width=4 head=none position="absolute" >}}        ← plain line
{{< arrow from="630,412" to="469,434" head=circle head-start=true head-end=false position="absolute" >}}
```

- Coordinates are slide pixels (1280 × 720). `to` is the **base** of the arrowhead: the tip lies `size × width` px further.
- `color="var(--talk-accent)"` uses a theme colour. Other options: `dash="4 8"`, `curve=0.3`, `bend=`, `label=`, `fragment=true` (drawn at a click).
- **Group by click.** Objects that appear (or disappear) together go in one fragment block:

```markdown
::: {.fragment .fade-in-then-out fragment-index=1}    ← shown at click 1 only
[]{.absolute left=222 top=407 width=200 height=125 border="1px solid black"}
{{< arrow from="170,595" to="345,595" width=1 size=6 position="absolute" >}}
[$t$]{.absolute .tb left=206 top=591}
:::
```

- **Diagrams** (block diagrams, flowcharts): a ```` ```{mermaid} ```` chunk inside a positioned box fills the box (centred, aspect ratio kept). Labels can hold maths, `"$$\hat{X}_i^T$$"`, rendered with the slides' KaTeX fonts; the colours follow the theme (`$mermaid-*` in `talk.scss`).
- **Repeated slides** (an outline shown several times): put the shared part in `_name.qmd` and write `{{< include _name.qmd >}}` in each slide.

## Boxes and shapes

```markdown
[$Q$]{.absolute .box left=568 top=488 width=100 height=125}            ← framed box, text centred
[NTD]{.absolute .filled left=400 top=200 width=150 height=70}          ← accent shape style
[NTD]{.absolute .filled left=400 top=300 width=150 height=70 shape=arrow-right}
[$\mathscr{X}$]{.absolute .box left=820 top=170 width=160 height=130 shape=cube depth=30}
```

- One line per object: a span `[text]{.absolute …}` is a box like a `::: {.absolute …}` div (use the div for several paragraphs or a list).
- `shape=` draws an outline behind the content: `arrow-right`, `arrow-left`, `arrow-up`, `arrow-down` (`head=`, `shaft=` in %), `shrink` / `grow` (trapezoid narrowing / widening to the right, `taper=` %), `parallelogram` (`slant=` %), `cube` (`depth=` px). `background=` fills it, `border="2px solid accent"` draws it.
- **Horizontal block diagrams**: items laid out in one row, centred vertically:

```markdown
::: {.absolute .flow left=555 top=200 width=645 height=310 size=18 gap=10}
[$X_i^T$]{.box width=42 height=100% dim="ft"}
[Encoder]{shape=shrink width=112 height=94% taper=25%}
[$Q_i^T$]{.box width=42 height=78}
$\xrightarrow{\;a()\;}$
[$\hat{X}_i^T$]{.box .dim-right width=42 height=100% dim="ft"}
:::
```

## More on clicks

- **One block per click**: `::: {.fragment fragment-index=2}` … `:::` around everything that appears at click 2 (`.fade-in-then-out`: shown at that click only; `delay=2` on the block delays it all).
- **Motion**: `::: {.fragment .move fragment-index=1 dx=-320 dy=0}` … `:::` moves its content at that click.
- **Sounds**: `[]{.absolute .audio-btn left=357 top=237 data-audio="media/x.mp3" play=1}`: the icon is there from the start, the sound plays at click 1.
- **Recaps**: `::: {.static}` … `:::` shows its content in its final state, without clicks, e.g. around `{{< include _outline.qmd >}}` to show again a slide that was built click by click.

## Titles, empty lines

- `## Title {top=15 left=150 size=40}` places the slide title like a PowerPoint title box (default: the title placeholder).
- An empty line, as in PowerPoint: `-` alone in a list (indented `  -` at level 2, but not right under a level-1 item: Markdown would read a heading underline), `&nbsp;` alone between paragraphs.
- Highlights along a diagonal: `hl="1-@diag intro verse1 verse2 …"` gives cell (k,k) the k-th colour (`@cols …`, `@rows …` likewise).

## Files

`_extension.yml` (format defaults), `talk.scss` (theme and all styles; colours and sizes are CSS variables), `talk.lua` (sections, side panels, citations, highlights, tilt, short attributes, appendix, TOC, YAML options), `audio.lua` (shortcode), `audio_icon.lua` (the speaker icon, shared by both filters), `talk.js` (audio, letter-box bleed, morph matching, R key for highlights, slide-number labels), `alphabetic.csl`, `fonts/` + `fonts.css`, `katex/` (offline maths).
