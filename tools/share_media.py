#!/usr/bin/env python3
"""share_media.py - move the media of every talk into the ONE shared folder _media/, without duplicates.

Layout (all_the_pres/ = one Quarto project, see its _quarto.yml):
    <deck>/index.qmd   a talk; its pictures and sounds are ../_media/<file>
    _media/...         the media of every talk, each file once (compared byte for byte)

Run from the project root (all_the_pres/):
    python _extensions/tools/share_media.py            dry run: lists what would change
    python _extensions/tools/share_media.py --apply    does it
(build_deck.sh runs it after converting a PowerPoint, so a new talk reuses the files already there.)

For every file in the media/ folder of a deck:
  1. a file with the same content already in _media/ is reused (whatever its name); otherwise the file is
     copied to _media/ at the same relative path as in media/, or, if that name is taken by a different
     file, with the suffix _<hash7> (image10.png of two PowerPoints are rarely the same picture);
  2. every reference "media/<path>" in the deck's .qmd / .yml / .yaml / .bib files becomes
     "../_media/<path>" (images, url(...), audio=, mark=, YAML logos, ...);
  3. the deck copy is deleted, then the emptied media/ folder.
Then it lists the files of _media/ that no deck mentions (left alone: delete them by hand if unused).
A deck = a folder of the project root, not starting with "_" or ".", that holds index.qmd.
Only identical files are found: the same picture saved again (other size, other format) is not.
"""
import argparse
import hashlib
import os
import re
import shutil
import sys
from pathlib import Path

SHARED = "_media"
TEXT = (".qmd", ".yml", ".yaml", ".bib")


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def files_under(folder):
    return sorted(p for p in folder.rglob("*") if p.is_file() and not p.name.startswith("."))


def decks_of(root):
    return sorted(d for d in root.iterdir()
                  if d.is_dir() and not d.name.startswith(("_", ".")) and (d / "index.qmd").is_file())


def text_files(deck):
    return sorted(p for p in deck.rglob("*") if p.is_file() and p.suffix in TEXT
                  and "_extensions" not in p.parts and not any(s.endswith("_files") for s in p.parts))


def ref_pattern(rel):
    # "media/<rel>" not preceded by a path character (so "_media/…", "x/media/…" are left alone)
    return re.compile(r"(?<![\w./-])media/" + re.escape(rel) + r"(?![\w.-])")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--apply", action="store_true", help="do it (default: dry run)")
    ap.add_argument("--root", default=".", help="project root (default: current folder)")
    args = ap.parse_args()

    root = Path(args.root).resolve()
    if not (root / "_quarto.yml").is_file():
        sys.exit(f"{root} has no _quarto.yml: run this from the project root (all_the_pres/)")
    shared = root / SHARED
    decks = decks_of(root)

    in_shared, taken = {}, set()                      # hash -> path in _media;  paths in _media
    if shared.is_dir():
        for p in files_under(shared):
            rel = p.relative_to(shared).as_posix()
            in_shared.setdefault(sha(p), rel)
            taken.add(rel)

    word = "" if args.apply else "(dry run) "
    todo = 0
    for deck in decks:
        media = deck / "media"
        if not media.is_dir():
            continue
        plan = []                                     # (rel in media/, rel in _media/, how)
        for p in files_under(media):
            rel, h = p.relative_to(media).as_posix(), sha(p)
            if h in in_shared:
                plan.append((rel, in_shared[h], "reused"))
                continue
            target = rel
            if target in taken:
                stem, dot, ext = target.rpartition(".")
                target = f"{stem}_{h[:7]}.{ext}" if dot else f"{target}_{h[:7]}"
            taken.add(target)
            in_shared[h] = target
            plan.append((rel, target, "new"))
            if args.apply:
                (shared / target).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(p, shared / target)
        if not plan:
            continue
        todo += len(plan)
        new = sum(1 for _, _, how in plan if how == "new")
        print(f"{word}{deck.name}: {len(plan)} file(s) -> {SHARED}/  ({new} new, {len(plan) - new} already there)")
        for rel, target, how in plan:
            if how == "reused" or target != rel:
                print(f"    media/{rel}  ->  {SHARED}/{target}" + ("   (same file, reused)" if how == "reused" else "   (name taken)"))
        # one pass per text file, every pattern at once
        table = {rel: target for rel, target, _ in plan}
        pat = re.compile(r"(?<![\w./-])media/(" + "|".join(re.escape(r) for r in sorted(table, key=len, reverse=True)) + r")(?![\w.-])")
        for f in text_files(deck):
            s = f.read_bytes().decode("utf-8")
            s2, k = pat.subn(lambda m: f"../{SHARED}/{table[m.group(1)]}", s)
            if k:
                print(f"    {f.relative_to(deck).as_posix()}: {k} reference(s) rewritten")
                if args.apply:
                    f.write_bytes(s2.encode("utf-8"))  # line endings untouched
        if args.apply:
            shutil.rmtree(media)

    if not todo:
        print("Nothing to move: no deck has a media/ folder.")
    # files of _media/ that no deck mentions
    if shared.is_dir() or not args.apply:
        texts = "".join(f.read_text("utf-8", errors="replace") for d in decks for f in text_files(d))
        if not args.apply:
            texts = re.sub(r"(?<![\w./-])media/", f"../{SHARED}/", texts)   # what it will be (approximately)
        unused = [r for r in sorted(taken) if f"{SHARED}/{r}" not in texts and r != "README.md"]
        if unused:
            print(f"\nIn {SHARED}/ but mentioned by no deck (left alone):")
            for r in unused:
                print(f"    {SHARED}/{r}")
    if todo and not args.apply:
        print("\nDry run: nothing changed. Run again with --apply to do it.")


if __name__ == "__main__":
    main()
