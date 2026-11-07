# Working instructions: talk template (read first in every conversation of this project)

Axel converts his PowerPoint talks to Quarto reveal.js with the reusable template **`talk`** (repository github.com/ax-le/my_talk_template, cloned as the `_extensions/` folder of each deck; format `talk-revealjs`). Every feature goes **into the template**, never into one deck only, because he has many similar talks.

## The two objectives (cascade)

1. **Rebuild the PowerPoint in Quarto (adapting the past).** The Quarto deck must look and click like the pptx: layout, click order, animations.
2. **A reusable template maintained by humans (the future).** For new decks: important features kept, decks short, readable and easy to tune by hand. Anything that takes a lot of deck code becomes a template feature (class, attribute, shortcode, standard extension).

Both matter; they come in this order: first rebuild, then generalise the code as much as possible while keeping the look and the clicks. **Current phase for the PhD deck: objective 2** (reduce `index.qmd`, move patterns into the template). On a conflict of details: native Quarto/Markdown over pixel resemblance, but never change click order or animations.

## Where

- On his computer, `C:\Users\a23marmo\Desktop\Projects\my_pres_into_quarto\` (Windows, CRLF line endings: compare files ignoring `\r`, write back with CRLF) holds:
  - `my_talk_template/`: the template repository (root = what a deck clones as `_extensions/`: `talk/`, `arrows/`, `tools/`, `tour/template.qmd`, README, AGENTS). Not a Quarto project: it renders nothing by itself.
  - `all_the_pres/`: the decks repository. `phd-defense-quarto/` (the PhD deck: `index.qmd`, `media/`, `refs.bib`, `_quarto.yml`) and `template/` (a deck with no content of its own, whose `_quarto.yml` only lists `_extensions/tour/template.qmd`: render the tour from there). Each deck's `_extensions/` is a git clone of the template (git-ignored). Edit the template in ONE clone (preferably `my_talk_template/`); Axel then runs `all_the_pres/push.cmd` on Windows or `push.sh` on Linux (= `sync.ps1` / `sync.sh push`, relative paths, deck folders found at every run, new decks get their `_extensions/` clone: commits/pushes that clone, pulls every other clone, then commits/pushes the decks) and `pull.cmd` at the start of a session. Agents do not commit from the desktop VM (git there needs delete permission for its lock files): leave the changes in the working tree and tell Axel to run push.cmd.
- Rendering: Quarto is not on the desktop VM by default; a tarball install in `$HOME/tools` works there (GitHub reachable), but Quarto's cache fails on the mounted folder: rsync the deck to `$HOME/work/deck` and render there. Headless screenshots: Playwright + `@sparticuz/chromium` (npm) in the VM, `tools/shoot_steps.js` with that executable; view the PNGs by copying them into the deck's `Claude outputs/` and staging them. Faster (2026-11-07): tar the deck (without `.git`, `*_files`, `*.html`) into `my_talk_template/Claude outputs/_snap_<date>.tgz` with device_bash, stage that one file, unpack it in the cloud container, install Quarto there (GitHub reachable from the container) and render/screenshot there with the preinstalled Playwright; write the changed files back with CRLF through device_commit_files. Checks: the rendered HTML before/after (identical when nothing should change; mask the random ids of quarto-arrows, `arrow-N`) and a pixel diff of every click step; converter passes: run each pass old/new on old converted decks (`Claude outputs/*.zip`) and compare the outputs.
- Agent reference: `my_talk_template/AGENTS.md` (mirror in this project: `claude/talk-template-AGENTS.md`) describes the template **as it is**. Read it before any change; update it in place after any change (current state, not a changelog) and refresh the project mirror. `my_talk_template/README.md` is the human guide (Axel's introduction, then the technical part); keep it in sync.

## Rules for every change

1. **Native first.** Quarto, Pandoc, reveal.js, KaTeX, Mermaid or a standard Quarto extension before custom code; a thin wrapper (class, shortcode, macro, YAML default) is fine.
2. **Factorise.** One general feature rather than near-duplicates; reuse the helpers listed in AGENTS.md.
3. **The template is the test suite.** `tour/template.qmd` (rendered from the deck as `_extensions/tour/template.qmd`) shows every feature, one feature per slide (never two features on a slide, never the same check twice), with an `<!-- EXPECT: … -->` comment. After every change: render it and the real deck, check every slide and click step (`tools/shoot_steps.js` before/after + pixel diff), and **tell Axel explicitly which features fail**. Every new feature gets a showcase slide.
4. **Decks are hand-written.** `index.qmd` is no longer rebuilt from the pptx (decided 2026-11-05); edit it directly. Style: one block per object or one block per click (`::: {.fragment [.fade-in-then-out] fragment-index=N}`), arrows with quarto-arrows, diagrams with Mermaid or `.flow`, grids with `cols=/rows=/hl=`, repeated slides with `{{< include _x.qmd >}}`, one-line objects as spans `[text]{.absolute .tb left= top=}`.

## Open points

- refs.bib was checked against the thesis bibliography on 2026-11-07 (every entry matches; Wu+22 is now the SMC 2022 paper, as in the thesis).
- "Barwise autosimilarity": the A(X)₄₅ highlight snapped to column 4, row 5 (`@4,5`); swap it to `@5,4` if the convention is row 4, column 5.
