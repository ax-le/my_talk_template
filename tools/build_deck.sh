#!/usr/bin/env bash
# Rebuild index.qmd from the PowerPoint, then render.
#   usage: _extensions/tools/build_deck.sh path/to/talk.pptx      (run from the deck folder, whose
#          _extensions/ is a clone of the template repository)
# Steps: pptx2qmd (conversion) → sections (section / side-panel slides) → cites (references → [@key])
#        → highlights (red overlays → hl=) → deck_patches (hand rewrites) → segments (rows of boxes → grid boxes) → captions (picture + name) → tidy (short attributes) → simplify (hand-editable style) → header + render
# For NEW talks only: the PhD deck (index.qmd) is now edited by hand and must not be rebuilt.
set -e
PPTX="$1"; T="$(dirname "$0")"; W="$(mktemp -d)"
TEST=1 BACKUP_FROM=67 python3 "$T/pptx2qmd.py" "$PPTX" "$W" > /dev/null   # TEST: test slides ("test slide"); BACKUP_FROM: appendix marker before this slide (backups numbered additional-1, …); SKIP=…: drop slides
cp "$W/slides.md" "$W/slides_final.md"
python3 "$T/sections.py" "$W/slides_final.md" > /dev/null
python3 "$T/cites.py" "$W/slides_final.md"
python3 "$T/highlights.py" "$W/slides_final.md"
python3 "$T/deck_patches.py" "$W/slides_final.md"
python3 "$T/segments.py" "$W/slides_final.md"                  # rows of touching boxes → grid boxes
python3 "$T/captions.py" "$W/slides_final.md"                  # picture + name above/below → captioned figure
python3 "$T/tidy.py" "$W/slides_final.md"                      # short attributes, defaults dropped
python3 "$T/simplify.py" "$W/slides_final.md" "$W/slides_final.md"   # hand-editable style (arrows, click groups, shapes…)
mkdir -p media && cp -r --update=none "$W/media/." media/        # images and audio (wav → mp3)
{ cat "$T/_header.yml"; echo; cat "$W/slides_final.md"; } > index.qmd
quarto render index.qmd
