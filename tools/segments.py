"""Boxes drawn side by side in PowerPoint → ONE grid box of the template (cols= rows= lines= hl=).

In PowerPoint, a bar divided into cells (song structure, bars, time lines) is drawn as many
separate rectangles placed side by side, so their borders double up. This pass finds, in each
slide, at least 3 framed boxes with the same top, height and border that touch each other
(gap or overlap of a few px), and writes them as one box:

    ::: {.absolute cols="158 157 …" lines=true style="left:…;top:…;width:…;height:…;border:…"}
    - Verse
    - [d]{.cell .fragment data-fragment-index=1}
    :::

Attributes shared by all the cells (e.g. the same click) move to the box; the others stay on
the cell (clicks, colours, highlights hl=, and the data-id of a box that morphs to the next
slide: the cell itself then morphs). A row without border whose boxes are all coloured is a
colour overlay (slides 8, 46): one box whose cells are coloured by hl= entries "CLICK-@cell
colour", colours named from the palette (tools/_header.yml first, then the template's).

Vertical stacks of at least 3 equal, empty framed rows (same left, width, border), e.g. the
barwise matrices X of slides 24 and 31, become ONE box with rows=N lines=true, the
highlights of each row turned into entries "STEPS@row".

Rotated boxes and drawn shapes are left alone. Runs before tidy.py (long style= form).
usage: python3 segments.py slides.md        (in place)
"""
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, __import__("os").path.dirname(__file__))
from tidy import parse, fmt          # noqa: E402

HERE = __import__("os").path.dirname(__file__)
# colour names: the deck's own palette (tools/_header.yml, talk: highlight: colors) first, then
# the template's palette. A colour of a converted overlay is written with its name.
TEMPLATE_PALETTE = {"red": "#C00000", "teal": "#69A1AB", "gold": "#F2C418", "orange": "#DC9528",
                    "purple": "#9A5D78", "green": "#4A845E", "brown": "#87492C", "navy": "#1A2E40",
                    "black": "#000000"}


def widths(cells):
    """cols= of a row: the number of cells when they are equal (within 2 px), else their widths"""
    w = [round(c["box"][2]) for c in cells]
    return str(len(w)) if max(w) - min(w) <= 2 else " ".join("%d" % x for x in w)


def palette():
    names = []
    try:
        txt = open(__import__("os").path.join(HERE, "_header.yml"), encoding="utf8").read()
        m = re.search(r'\n  highlight:\n(?:    .*\n)*?    colors:[^\n]*\n((?:      [\w-]+:.*\n)+)', txt)
        if m:
            for k, v in re.findall(r'^\s+([\w-]+):\s*"?(#[0-9A-Fa-f]{6})"?', m.group(1), re.M):
                names.append((k, v.upper()))
    except OSError:
        pass
    names += [(k, v.upper()) for k, v in TEMPLATE_PALETTE.items()]
    return names


PALETTE = palette()


def colour_name(css):
    """rgba(242,196,24,0.50) → ("intro", 0.5) when the colour is in the palette"""
    m = re.fullmatch(r'rgba?\((\d+),\s*(\d+),\s*(\d+)(?:,\s*([\d.]+))?\)', css.replace(" ", ""))
    if m:
        hexv = "#%02X%02X%02X" % tuple(int(x) for x in m.groups()[:3]); alpha = float(m.group(4) or 1)
    elif re.fullmatch(r'#[0-9A-Fa-f]{6}', css):
        hexv, alpha = css.upper(), 1.0
    else:
        return None, None
    for k, v in PALETTE:
        if v == hexv: return k, alpha
    return hexv, alpha


BLOCK = re.compile(r'^::: \{([^{}\n]*)\}\n((?:(?!:::)[^\n]*\n)*?):::\n', re.M)
TOL = 4            # px of gap / overlap between two touching boxes
SKIP_CLASSES = {".ttl", ".move", ".tilt", ".ln-box", ".grp", ".hl-host"}


def style_of(kv):
    d = dict(kv)
    out = {}
    for part in d.get("style", "").split(";"):
        if ":" in part:
            k, v = part.split(":", 1)
            out[k.strip()] = v.strip()
    return out


def px(v):
    m = re.fullmatch(r'(-?[\d.]+)px', v or "")
    return float(m.group(1)) if m else None


def candidate(m, ids_count):
    ident, classes, kv = parse(m.group(1))
    if ".absolute" not in classes or not ({".tb", ".shp"} & set(classes)): return None
    if SKIP_CLASSES & set(classes): return None
    d = dict(kv)
    if any(k in d for k in ("rotate-x", "rotate-y", "rotate-z", "face", "cols", "rows")): return None   # already a grid
    st = style_of(kv)
    if "transform" in st: return None
    if "border" not in st and "background" not in st: return None      # framed box, or colour overlay
    box = [px(st.get(k)) for k in ("left", "top", "width", "height")]
    if None in box: return None
    body = m.group(2)
    if "<svg" in body or "\n:::" in body: return None
    text = " ".join(l.strip() for l in body.splitlines() if l.strip())
    if text.startswith(("- ", "1. ", "<div")): return None          # lists / raw blocks inside
    morph = bool(d.get("data-id")) and ids_count[d["data-id"]] > 1
    hl = [[k, v] for k, v in kv if k == "hl" or k.startswith("hl-")]
    return dict(m=m, ident=ident, classes=classes, kv=kv, st=st, box=box, text=text, morph=morph, hl=hl,
                did=d.get("data-id"), border=st.get("border", "none"))


def common(cells, getter):
    vals = [getter(c) for c in cells]
    return vals[0] if all(v == vals[0] for v in vals) else None


def frag_of(c):
    d = dict(c["kv"])
    fr = [x for x in c["classes"] if x == ".fragment" or x.startswith((".fade", ".grow", ".shrink", ".semi", ".highlight", ".strike"))]
    return (tuple(fr), d.get("data-fragment-index"))


def snap(v, others):
    """align on the most common value of the other rows within TOL px (rows drawn by hand
    in PowerPoint are rarely aligned to the pixel)"""
    near = Counter(round(o) for o in others if abs(o - v) <= TOL)
    return near.most_common(1)[0][0] if near else v


def build_overlay(cells, lefts=(), rights=()):
    """a row of coloured boxes without border (a colour overlay on an image) → ONE box whose
    cells are coloured by hl= at their clicks: hl="1-@1 intro; 2-@2 verse1; …" """
    first = cells[0]
    left, top, height = first["box"][0], first["box"][1], first["box"][3]
    right = max(c["box"][0] + c["box"][2] for c in cells)
    left, right = snap(left, lefts), snap(right, rights)
    st = {"left": "%dpx" % round(left), "top": "%dpx" % round(top),
          "width": "%dpx" % round(right - left), "height": "%dpx" % round(height)}
    entries, alphas, radii = [], Counter(), Counter()
    for k, c in enumerate(cells, 1):
        name, alpha = colour_name(c["st"]["background"])
        alphas[alpha] += 1
        if c["st"].get("border-radius"): radii[round(px(c["st"]["border-radius"]) or 0)] += 1
        fr, idx = frag_of(c)
        step = (idx or "1") + "-" if ".fragment" in fr else "0-"
        entries.append("%s@%d %s" % (step, k, name))
    kv = [["cols", widths(cells)], ["hl", "; ".join(entries)]]
    a = alphas.most_common(1)[0][0]
    if a is not None and abs(a - 0.5) > 0.01: kv.append(["hl-opacity", "%g" % a])
    if radii: kv.append(["hl-radius", str(radii.most_common(1)[0][0])])
    kv.append(["style", ";".join("%s:%s" % (k, v) for k, v in st.items())])
    return "::: {%s}\n:::\n\n" % fmt(None, [".absolute"], kv)


def build(cells, lefts=(), rights=()):
    if cells[0]["border"] == "none" and all(colour_name(c["st"].get("background", ""))[0] for c in cells) \
            and not any(c["text"] or c["morph"] for c in cells):
        return build_overlay(cells, lefts, rights)
    first, last = cells[0], cells[-1]
    left, top, height = first["box"][0], first["box"][1], first["box"][3]
    right = max(c["box"][0] + c["box"][2] for c in cells)
    left, right = snap(left, lefts), snap(right, rights)
    st = {"left": "%dpx" % round(left), "top": "%dpx" % round(top),
          "width": "%dpx" % round(right - left), "height": "%dpx" % round(height)}
    if first["border"] != "none": st["border"] = first["border"]
    fs = Counter(c["st"].get("font-size") for c in cells if c["st"].get("font-size")).most_common(1)
    col = Counter(c["st"].get("color") for c in cells if c["st"].get("color")).most_common(1)
    if fs: st["font-size"] = fs[0][0]
    if col: st["color"] = col[0][0]
    shared_frag = common(cells, frag_of)
    classes = [".absolute"]
    kv = []
    if shared_frag and shared_frag[0]:
        classes += list(shared_frag[0])
        if shared_frag[1]: kv.append(["data-fragment-index", shared_frag[1]])
    kv.append(["cols", widths(cells)])
    if "border" in st: kv.append(["lines", "true"])
    kv.append(["style", ";".join("%s:%s" % (k, v) for k, v in st.items())])
    lines = ["::: {%s}" % fmt(None, classes, kv)]
    for c in cells:
        cls, ckv, cst = [".cell"], [], []
        if not shared_frag:
            fr, idx = frag_of(c)
            cls += list(fr)
            if idx: ckv.append(["data-fragment-index", idx])
        for k in ("font-size", "color"):
            if c["st"].get(k) and c["st"].get(k) != st.get(k): cst.append("%s:%s" % (k, c["st"][k]))
        for k in ("background", "border-radius"):
            if c["st"].get(k): cst.append("%s:%s" % (k, c["st"][k]))
        if c["morph"]: ckv.append(["data-id", c["did"]])       # the cell itself morphs (auto-animate)
        ckv += c["hl"]                                           # highlights of the box → of the cell
        if cst: ckv.append(["style", ";".join(cst)])
        if len(cls) > 1 or ckv:
            lines.append("- [%s]{%s}" % (c["text"], fmt(c["ident"], cls, ckv)))
        else:
            lines.append("- " + (c["text"] or "[]{.cell}"))
    if all(l == "- []{.cell}" for l in lines[1:]): lines = lines[:1]   # empty cells: no list at all
    lines += [":::", ""]
    return "\n".join(lines) + "\n"


def cluster(cands, key, tol_keys):
    """groups of candidates with the same key and close values (within TOL px)"""
    groups = []
    for c in cands:
        for g in groups:
            g0 = g[0]
            if key(g0) == key(c) and all(abs(f(g0) - f(c)) <= TOL for f in tol_keys):
                g.append(c); break
        else:
            groups.append([c])
    return groups


def chains_of(group, start, length):
    """chains of boxes, each one starting where the previous ends (±TOL); a box that overlaps
    the row (a frame drawn around it, a label) does not break the chain"""
    group.sort(key=start)
    chains = []
    for c in group:
        best = None
        for ch in chains:
            gap = start(c) - (start(ch[-1]) + length(ch[-1]))
            if -TOL <= gap <= TOL and (best is None or abs(gap) < best[0]): best = (abs(gap), ch)
        if best: best[1].append(c)
        else: chains.append([c])
    return [ch for ch in chains if len(ch) >= 3]


def build_grid(rows):
    """a vertical stack of equal empty rows → ONE box with rows=N lines=true; the
    highlights of each row become entries of the box (hl="2-4" on row 3 → "2-4@3")"""
    first = rows[0]
    left = round(Counter(round(c["box"][0]) for c in rows).most_common(1)[0][0])
    width = round(Counter(round(c["box"][2]) for c in rows).most_common(1)[0][0])
    top = round(first["box"][1])
    bottom = round(rows[-1]["box"][1] + rows[-1]["box"][3])
    st = {"left": "%dpx" % left, "top": "%dpx" % top, "width": "%dpx" % width, "height": "%dpx" % (bottom - top)}
    if first["border"] != "none": st["border"] = first["border"]
    if first["st"].get("background"): st["background"] = first["st"]["background"]
    shared = common(rows, frag_of)
    classes = [".absolute", ".shp"] + list(shared[0])
    kv = [["data-fragment-index", shared[1]]] if shared[1] else []
    entries = []
    for k, c in enumerate(rows, 1):
        for key, v in c["hl"]:
            for e in v.split(";"):
                e = e.strip()
                if not e: continue
                m = re.match(r'^(\S+)(\s+.*)?$', e)
                entries.append("%s@%d%s" % (m.group(1), k, m.group(2) or ""))
    kv += [["rows", "%d" % len(rows)], ["lines", "true"]]
    if entries: kv.append(["hl", "; ".join(entries)])
    kv.append(["style", ";".join("%s:%s" % (k, v) for k, v in st.items())])
    return "::: {%s}\n:::\n\n" % fmt(None, classes, kv)


def grid_ok(rows):
    if any(c["text"] or c["morph"] for c in rows): return False
    if common(rows, frag_of) is None: return False
    if common(rows, lambda c: c["st"].get("background")) is None and any(c["st"].get("background") for c in rows): return False
    for c in rows:
        if any(k != "hl" for k, _ in c["hl"]): return False
        if any("@" in v for _, v in c["hl"]): return False
    hs = [c["box"][3] for c in rows]
    return max(hs) - min(hs) <= TOL


def process_slide(text, ids_count):
    cands = [c for c in (candidate(m, ids_count) for m in BLOCK.finditer(text)) if c]
    edits = []          # (start, end, replacement)
    used = set()
    # 1. horizontal rows → one grid box with cols= (cells may differ in width and carry text, clicks, morphs)
    rows = []
    for g in cluster(cands, lambda c: c["border"], [lambda c: c["box"][1], lambda c: c["box"][3]]):
        rows += chains_of(g, lambda c: c["box"][0], lambda c: c["box"][2])
    # a borderless row is a colour overlay: every cell must have a colour
    rows = [ch for ch in rows if ch[0]["border"] != "none" or all(c["st"].get("background") for c in ch)]
    lefts = [ch[0]["box"][0] for ch in rows]
    rights = [max(c["box"][0] + c["box"][2] for c in ch) for ch in rows]
    for ch in rows:
        first = min(ch, key=lambda c: c["m"].start())
        edits.append((first["m"].start(), first["m"].end(), build(ch, lefts, rights)))
        for c in ch:
            used.add(id(c))
            if c is not first: edits.append((c["m"].start(), c["m"].end(), ""))
    # 2. vertical stacks of equal empty rows → one grid box with rows=N lines=true
    rest = [c for c in cands if id(c) not in used and c["border"] != "none"]
    stacks = []
    for g in cluster(rest, lambda c: c["border"], [lambda c: c["box"][0], lambda c: c["box"][2]]):
        stacks += [ch for ch in chains_of(g, lambda c: c["box"][1], lambda c: c["box"][3]) if grid_ok(ch)]
    for ch in stacks:
        first = min(ch, key=lambda c: c["m"].start())
        edits.append((first["m"].start(), first["m"].end(), build_grid(ch)))
        for c in ch:
            if c is not first: edits.append((c["m"].start(), c["m"].end(), ""))
    for a, b, r in sorted(edits, reverse=True):
        text = text[:a] + r + text[b:]
    if edits: text = re.sub(r'\n{3,}', '\n\n', text)   # removed blocks leave blank lines
    return text, len(rows), len(stacks)


def main(path):
    s = open(path, encoding="utf8").read()
    ids_count = Counter(m[1] for m in re.findall(r'data-id=("?)([^"\s{}]+)\1', s))
    parts = re.split(r'(?m)^(?=## )', s)
    nr = ns = 0
    for i, p in enumerate(parts):
        parts[i], a, b = process_slide(p, ids_count)
        nr += a; ns += b
    s = "".join(parts)
    open(path, "w", encoding="utf8").write(s)
    print("segments: %d rows of touching boxes and %d stacks of rows → grid boxes" % (nr, ns))


if __name__ == "__main__":
    main(sys.argv[1])
