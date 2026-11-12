#!/usr/bin/env python3
"""share_media.py - put the media files used by several talks into ONE shared folder.

Layout (all_the_pres/ = one Quarto project, see its _quarto.yml):
    <deck>/index.qmd, <deck>/media/...   a talk and the files only it uses
    _media/...                           files shared by several talks (../_media/<file> from a talk)

Run from the project root (all_the_pres/):
    python _extensions/tools/share_media.py            dry run: lists what would change
    python _extensions/tools/share_media.py --apply    does it

For every file that exists, byte for byte, in the media/ of two decks or more (or already in _media/):
  1. it is copied once into _media/, at the same relative path as in media/ (a name already taken by a
     different file gets the suffix _<hash>); a copy already in _media/ is reused;
  2. every reference "media/<path>" in the .qmd / .yml / .yaml / .bib files of those decks becomes
     "../_media/<path>" (images, audio=, mark=, YAML logos, ...);
  3. the deck copies are deleted (an emptied folder too).
Then it lists the files of _media/ that no deck mentions any more (left alone).
A deck = a folder of the project root, not starting with "_" or ".", that holds index.qmd.
"""
import argparse
import hashlib
import os
import re
import shutil
import sys
from collections import defaultdict
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

    by_hash = defaultdict(list)                       # hash -> [(deck, rel)]
    for deck in decks:
        media = deck / "media"
        if media.is_dir():
            for p in files_under(media):
                by_hash[sha(p)].append((deck, p.relative_to(media).as_posix()))
    in_shared = {}                                    # hash -> rel in _media
    taken = set()
    if shared.is_dir():
        for p in files_under(shared):
            rel = p.relative_to(shared).as_posix()
            in_shared.setdefault(sha(p), rel)
            taken.add(rel)

    moves = []                                        # (hash, target rel, [(deck, rel)])
    for h, uses in sorted(by_hash.items(), key=lambda kv: kv[1][0][1]):
        if len({d for d, _ in uses}) < 2 and h not in in_shared:
            continue
        target = in_shared.get(h)
        if target is None:
            target = uses[0][1]
            if target in taken:
                stem, dot, ext = target.rpartition(".")
                target = f"{stem}_{h[:7]}.{ext}" if dot else f"{target}_{h[:7]}"
            taken.add(target)
            in_shared[h] = target
        moves.append((h, target, uses))

    if not moves:
        print("Nothing to share: no file is used by two decks.")
    word = "" if args.apply else "(dry run) "
    for h, target, uses in moves:
        print(f"{word}{SHARED}/{target}")
        src = uses[0][0] / "media" / uses[0][1]
        dst = shared / target
        if args.apply and not dst.exists():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
        for deck, rel in uses:
            pat, n = ref_pattern(rel), 0
            for f in text_files(deck):
                raw = f.read_bytes()
                s = raw.decode("utf-8")
                s2, k = pat.subn(f"../{SHARED}/{target}", s)
                if k:
                    n += k
                    if args.apply:
                        f.write_bytes(s2.encode("utf-8"))   # line endings untouched
            print(f"    {deck.name}/media/{rel}: {n} reference(s)")
            if args.apply:
                p = deck / "media" / rel
                p.unlink()
                d = p.parent
                while d != deck / "media" and not any(d.iterdir()):
                    d.rmdir()
                    d = d.parent

    # files of _media/ that no deck mentions
    if shared.is_dir():
        texts = "".join(f.read_text("utf-8", errors="replace") for d in decks for f in text_files(d))
        unused = [r for r in sorted(taken | {t for _, t, _ in moves})
                  if f"{SHARED}/{r}" not in texts and (shared / r).exists() and r != "README.md"]
        if unused and args.apply:
            print("\nIn _media/ but mentioned by no deck (left alone):")
            for r in unused:
                print(f"    {SHARED}/{r}")
    if moves and not args.apply:
        print("\nDry run: nothing changed. Run again with --apply to do it.")


if __name__ == "__main__":
    main()
