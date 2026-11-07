"""A picture and the one-line text box just above (or below) it → one captioned figure.

In PowerPoint a photo and its name are two unrelated objects. Here they become one native
Quarto figure (the caption is the name), placed with the template's .caption-top /
.caption-bottom classes; the box is the picture's box, the caption hangs above (below) it:

    ::: {.absolute .caption-top style="left:34px;top:397px;width:164px;font-size:…"}
    ![Frédéric Bimbot](media/image4.jpg){width=164 height=230}
    :::

A text box is taken as the caption of a picture when it holds a single short line, has no
frame, colour or click of its own, lies within a few px above (or below) the picture, and is
aligned with it (same left edge of the text, or same centre). Objects that morph to another
slide (data-id used twice) are left alone. Runs before tidy.py (long style= form).
usage: python3 captions.py slides.md        (in place)
"""
import re
import sys
from collections import Counter

sys.path.insert(0, __import__("os").path.dirname(__file__))
from shared import parse, fmt, BLOCK, style_of, px as num          # noqa: E402

IMAGE = re.compile(r'^!\[\]\(([^)\s]+)\)\{([^{}\n]*)\}[ \t]*\n', re.M)
GAP = 30           # px between the text box and the picture
PAD = 9.6          # inner left margin of a converted text box


def texts(slide, ids):
    for m in BLOCK.finditer(slide):
        ident, classes, kv = parse(m.group(1))
        d = dict(kv)
        if ".absolute" not in classes or ".tb" not in classes: continue
        if set(classes) - {".absolute", ".tb", ".va-ctr", ".va-b"}: continue      # clicks, title…
        if any(k.startswith("hl") for k in d) or (d.get("data-id") and ids[d["data-id"]] > 1): continue
        st = style_of(d)
        if any(k in st for k in ("border", "background", "transform")): continue
        lines = [l.strip() for l in m.group(2).splitlines() if l.strip()]
        if len(lines) != 1 or lines[0].startswith(("-", "<", "$", "!", ":::")) or len(lines[0]) > 60: continue
        l, t, w = num(st.get("left")), num(st.get("top")), num(st.get("width"))
        if None in (l, t, w): continue
        fs = num(st.get("font-size")) or 22.3
        h = num(st.get("height")) or fs * 1.2 + 9.6
        yield dict(m=m, l=l, t=t, w=w, h=h, text=lines[0], st=st,
                   align=st.get("text-align", "left"))


def images(slide, ids):
    for m in IMAGE.finditer(slide):
        ident, classes, kv = parse(m.group(2))
        d = dict(kv)
        if classes != [".absolute"] or any(k.startswith(("hl", "rotate", "face")) for k in d): continue
        if d.get("data-id") and ids[d["data-id"]] > 1: continue
        box = [num(d.get(k)) for k in ("left", "top", "width", "height")]
        if None in box or "style" in d: continue
        if box[2] < 60 or box[3] < 60: continue                # arrows, icons: not photos / figures
        yield dict(m=m, src=m.group(1), box=box)


def aligned(t, im):
    l, w = im["box"][0], im["box"][2]
    if t["align"] == "center": return abs((t["l"] + t["w"] / 2) - (l + w / 2)) <= 20
    return abs(t["l"] + PAD - l) <= 15 or abs((t["l"] + t["w"] / 2) - (l + w / 2)) <= 20


def process_slide(slide, ids):
    tx, ims = list(texts(slide, ids)), list(images(slide, ids))
    edits, used = [], set()
    for im in ims:
        l, top, w, h = im["box"]
        best = None
        for t in tx:
            if id(t) in used or not aligned(t, im): continue
            above = top - (t["t"] + t["h"])
            below = t["t"] - (top + h)
            if -10 <= above <= GAP: cand = ("top", abs(above))
            elif -10 <= below <= GAP: cand = ("bottom", abs(below))
            else: continue
            if best is None or cand[1] < best[0][1]: best = (cand, t)
        if not best: continue
        (where, _), t = best
        used.add(id(t))
        st = {"left": "%dpx" % round(l), "top": "%dpx" % round(top),
              "width": "%dpx" % round(w)}
        for k in ("font-size", "color"):
            if t["st"].get(k): st[k] = t["st"][k]
        box = fmt(None, [".absolute", ".caption-" + where], [["style", ";".join("%s:%s" % kv for kv in st.items())]])
        fig = "::: {%s}\n![%s](%s){width=%d height=%d}\n:::\n" % (box, t["text"], im["src"], round(w), round(h))
        edits += [(im["m"].start(), im["m"].end(), fig), (t["m"].start(), t["m"].end(), "")]
    for a, b, r in sorted(edits, reverse=True):
        slide = slide[:a] + r + slide[b:]
    if edits: slide = re.sub(r'\n{3,}', '\n\n', slide)
    return slide, len(edits) // 2


def main(path):
    s = open(path, encoding="utf8").read()
    ids = Counter(m[1] for m in re.findall(r'data-id=("?)([^"\s{}]+)\1', s))
    parts = re.split(r'(?m)^(?=## )', s)
    n = 0
    for i, p in enumerate(parts):
        parts[i], k = process_slide(p, ids)
        n += k
    open(path, "w", encoding="utf8").write("".join(parts))
    print("captions: %d pictures with their caption" % n)


if __name__ == "__main__":
    main(sys.argv[1])
